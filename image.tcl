#
# tclpdf - PDF generation for Tcl
#
# image - placing JPEG, PNG and TIFF pictures (8.9.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The public face of the image topic. Reading the three formats happens in
# imageJpeg.tcl, imagePng.tcl, imagePngAlpha.tcl, imageTiff.tcl and
# imageTiffStreams.tcl, which nothing outside this file loads.
#
# Usage:
#
#   $doc image embed logo assets/logo.png
#   $doc image place logo -at {20 20} -width 40
#   $doc page add
#   $doc image place logo -at {20 20} -width 40    ;# no second copy
#
#   $doc image draw assets/photo.jpg -at {20 70} -size {80 60}
#
#   $doc image place logo -at {190 20} -width 40 -align right
#   $doc image place photo -at {20 40} -fit {80 50} -fitMode cover \
#       -align center -valign middle
#
# -at names the top left corner of the box a picture goes into, as it names
# the top left corner of a [rect]; -align and -valign say where in that box
# the picture sits, in the words the rest of this package already uses for
# the two axes. Without -fit the box has no size, so the same two options are
# the plain anchor - a logo whose RIGHT edge is to sit on the type area's
# right margin is -at {190 20} -align right, and nobody has to measure the
# picture first. See [fitAnchor] and [fitCheck] in page.tcl.
#
# A picture need not become an object at all. Placed with -inline 1 it is
# written INTO the content stream (8.9.7) - BI, an abbreviated dictionary,
# ID, the bytes, EI - with no object number, no entry in the page's resources
# and no way of being used twice. That is the case for it and the whole of
# its cost, and it is why -inline is ASKED for rather than decided by size
# here: whether a picture occurs once is something the caller knows and the
# writer does not. See [ImageInline].
#
#   $doc image embed seal seal.png -stencil 1
#   $doc image place seal -at {20 20} -width 20 -inline 1
#
# A picture need not stay a picture. Embedded with -stencil 1 a one-bit file
# becomes an image mask (8.9.6.2): it carries no colour of its own, and every
# placement paints the fill colour then in force through its bits. Embedded
# with -mask <alias> a picture wears a SECOND embedded picture as its mask -
# a stencil becomes the /Mask of explicit masking (8.9.6.3), a greyscale
# picture the /SMask of a soft mask (11.6.5.2). Both are decided at the
# embedding, because both decide what the XObject IS:
#
#   $doc image embed stamp logo.png -stencil 1
#   $doc style -fill {0.7 0.1 0.1}
#   $doc image place stamp -at {20 20} -width 40   ;# painted red
#
#   $doc image embed fade vignette.png
#   $doc image embed photo photo.jpg -mask fade
#
# An embedded picture becomes a PDF object the FIRST time it is placed, not
# when it is embedded. A caller who embeds a logo and then takes a different
# branch does not pay for it - the same rule the font module follows.
#
# Two conventions that hold everywhere in this package: -at names the TOP left
# corner, and sizes are in the document unit. Pixels only appear when a size
# has to be derived, and then through the resolution: the one the FILE states
# where it states one, 72 dpi where it does not, and whatever -dpi says when a
# caller says it. A 200 dpi scan 1728 pixels wide is 219 mm wide and is placed
# that wide; read as 72 dpi it would have been 610 mm and off the sheet.
#
# What the file said and what was assumed are two different answers, and
# [image info] keeps them apart - see [ImageInfo].
#
# ONE TIFF MAY BECOME SEVERAL IMAGE XOBJECTS, and that is the one place where
# this module treats a format specially. Every stateful compression restarts
# in every strip, so the strips of such a file cannot be joined into one
# stream - imageTiffStreams.tcl hands back one part per strip instead, each
# with the rows it holds. They are placed as n cm/Do pairs inside the ONE
# q ... Q of the placement (see [ImageStack]), not wrapped in a form XObject:
# 80 of 194 measured files are single-stripped and both real scans have one
# strip per page, so the stack is the exception and stays local. A form
# XObject would also cost the picture the ability to be another one's /SMask.
#
# Above [stripLimit] parts the picture is refused rather than stacked.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::filter 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::io 1.0-
package require tclpdf::imageJpeg 1.0-
package require tclpdf::imagePng 1.0-
package require tclpdf::imageTiff 1.0-
package require tclpdf::imageTiffStreams 1.0-
# For [IccInspect] and [IccProfileObject]: a picture's embedded profile goes
# through the same reader and the same one-stream-per-profile registry as a
# registered colour space and the PDF/A output intent.
package require tclpdf::color 1.0-
package require tclpdf::graphics 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::image {
  # How many image XObjects one TIFF may be stacked out of. A stateful
  # compression restarts in every strip, so a striped file becomes one
  # XObject per strip - and a page holding two thousand of them is not a
  # picture any more, it is a denial of service with a /Do in front of it.
  # 13 of 194 measured files lie above this line and the largest has 1922
  # strips; both real scans in that corpus have ONE strip per page.
  variable stripLimit 256

  # How much image data one inline image may carry.
  #
  # 8.9.7 says it twice and says SHOULD both times: the inline format "should
  # be used only for small images (4096 bytes or less)", and "the value of
  # the Length key should not exceed 4096 bytes". So the line is a
  # recommendation of the standard and the refusal above it is this package's
  # decision - taken because an inline image is worse than an image XObject
  # in every way but one, and the exception is exactly the picture that is
  # smaller than the machinery around it: a bullet, a rule, a seal, a fax
  # stamp, for which an object, an entry in the page's resources and a line
  # in the cross-reference table cost more than the picture itself. Above the
  # line the caller is almost certainly mistaken, and the way out is one
  # option away - so the picture is refused rather than quietly written the
  # other way, which a caller who asked for BI ... EI and got a /Do would
  # have no way to notice.
  variable inlineLimit 4096

  # Table 91: the entries an inline image object holds, and nothing else -
  # "entries other than those listed shall be ignored" (8.9.7), which is why
  # what cannot be expressed here is refused rather than written out in full
  # and left for a reader to drop on the floor. Intent is the one entry with
  # no abbreviation; Length is PDF 2.0 and is written only into a 2.0 file,
  # where 8.9.7 says it "shall be present on all inline images".
  #
  # Type, Subtype, Mask and SMask are not in the table, and an SMask could
  # not be there anyway: it names a stream object, and a content stream shall
  # contain no indirect references (7.8.2).
  variable inlineKeys {
    BitsPerComponent BPC ColorSpace CS Decode D DecodeParms DP Filter F
    Height H ImageMask IM Intent Intent Interpolate I Length L Width W
  }

  # Table 92, the colour space half. /I is the quirk worth knowing: as a KEY
  # it is Interpolate, as a colour space VALUE it is Indexed, and the two may
  # stand in one dictionary. 8.9.7 admits nothing else - "it shall not be a
  # CIE-based colour space or a special colour space, with the exception of a
  # limited form of Indexed colour space whose base colour space is a device
  # space".
  variable inlineSpaces {/DeviceGray /G /DeviceRGB /RGB /DeviceCMYK /CMYK}

  # Table 92, the filter half. Only /Fl, /DCT, /RL and /CCF are ever written
  # by this package - the three ASCII filters and /LZW stand here because the
  # table has them, not because anything produces one. The three that are
  # ABSENT from the table are absent on purpose: JPXDecode, JBIG2Decode and
  # Crypt "shall not be used with inline images".
  variable inlineFilters {
    /ASCIIHexDecode /AHx /ASCII85Decode /A85 /LZWDecode /LZW
    /FlateDecode /Fl /RunLengthDecode /RL /CCITTFaxDecode /CCF
    /DCTDecode /DCT
  }
}

# The image dictionary of an XObject, written the way an inline image writes
# it: abbreviated keys, abbreviated colour space and filter names. The same
# pairs the format readers hand to [ImageObject] go through here, which is
# why nothing about a picture is decided twice - what an inline image cannot
# express is refused, and everything else comes out of the ONE place that
# knows what a JPEG, a PNG or a TIFF turns into.
proc ::tclpdf::image::inlinePairs {pairs} {
  variable inlineKeys
  set result {}
  foreach {key value} $pairs {
    if {![dict exists $inlineKeys $key]} {
      return -code error -errorcode [list TCLPDF IMAGE INLINE ENTRY $key] \
          "tclpdf: an inline image object holds the entries of ISO 32000-2,\
          Table 91 and $key is not one of them - entries other than those\
          listed shall be ignored (8.9.7), so writing it out in full would\
          not carry it, it would lose it; leave -inline off and the picture\
          goes into the file as an image XObject, whose dictionary has room\
          for it (Table 87)"
    }
    switch -- $key {
      ColorSpace {set value [inlineSpace $value]}
      Filter {set value [inlineFilter $value]}
    }
    lappend result [dict get $inlineKeys $key] $value
  }
  return $result
}

# A colour space as an inline image names it (Table 92). A device space
# becomes its abbreviation; an /Indexed array keeps its hival and its lookup
# string and has its head and its base abbreviated. An ICCBased array never
# reaches here - 8.9.7 admits no CIE-based space, and the picture is refused
# where it is built, with the way out in the message.
proc ::tclpdf::image::inlineSpace {value} {
  variable inlineSpaces
  if {[dict exists $inlineSpaces $value]} {
    return [dict get $inlineSpaces $value]
  }
  if {[regexp {^\[/Indexed (/Device[A-Za-z]+) (.+)$} $value -> base rest]
      && [dict exists $inlineSpaces $base]} {
    return "\[/I [dict get $inlineSpaces $base] $rest"
  }
  return -code error -errorcode [list TCLPDF IMAGE INLINE SPACE $value] \
      "tclpdf: the colour space of an inline image is a device space or a\
      limited Indexed space over one, and shall not be a CIE-based or a\
      special colour space (ISO 32000-2, 8.9.7) - \"$value\" is neither of\
      the two admitted; leave -inline off and the picture goes into the file\
      as an image XObject, which may name any colour space"
}

# A filter as an inline image names it (Table 92) - one name, or the array of
# them 8.9.7's own example shows ("/F [/A85 /LZW]"), which this package does
# not currently produce and reads anyway rather than refusing what the
# standard prints.
proc ::tclpdf::image::inlineFilter {value} {
  variable inlineFilters
  if {[string index $value 0] eq "\["} {
    return "\[[join [lmap name [string range $value 1 end-1] {
        inlineFilter $name}] { }]\]"
  }
  if {[dict exists $inlineFilters $value]} {
    return [dict get $inlineFilters $value]
  }
  # The three that are missing from Table 92 are missing because they are
  # forbidden, and saying which of the two it is saves the caller the search.
  if {$value in {/JPXDecode /JBIG2Decode /Crypt}} {
    set why "$value shall not be used with inline images"
  } else {
    set why "an inline image names its filter by the abbreviations of ISO\
        32000-2, Table 92 and there is none for \"$value\""
  }
  return -code error -errorcode [list TCLPDF IMAGE INLINE FILTER $value] \
      "tclpdf: $why (ISO 32000-2, 8.9.7) - leave -inline off and the picture\
      goes into the file as an image XObject"
}

oo::define ::tclpdf::document::document {

  # $doc image embed <alias> ?path? ?-data bytes? ?-type auto|jpeg|png|tiff?
  # $doc image place <alias> ?-at {x y}? ?-size {w h}? ?-inline bool? ...
  # $doc image draw  ?path? ?-data bytes? ?-at {x y}? ...
  # $doc image info  <alias>
  # $doc image names
  method image {subcommand args} {
    switch -- $subcommand {
      embed {return [my ImageEmbed {*}$args]}
      place {return [my ImagePlace {*}$args]}
      draw {return [my ImageDraw {*}$args]}
      info {return [my ImageInfo {*}$args]}
      size {return [my ImageSize {*}$args]}
      names {return [dict keys [my state images]]}
      default {
        return -code error "tclpdf: unknown image subcommand \"$subcommand\" -\
            known are: embed, place, draw, info, size, names"
      }
    }
  }

  # A file name, or the bytes themselves.
  #
  # -data is for the image that never was a file: a canvas posted from a
  # browser, a plot from a subprocess, a BLOB out of a database. Writing it to
  # a temporary file first works and is what a caller had to do until now - but
  # [svg] has taken markup this way from the start, and two commands of one
  # package answering the same question differently is the kind of seam that
  # gets discovered rather than read.
  #
  # The name stays FIRST and positional, as it was; -data simply replaces the
  # path that would have followed it.
  method ImageEmbed {args} {
    if {![llength $args]} {
      return -code error "tclpdf: image embed needs a name"
    }
    set alias [lindex $args 0]
    set args [lrange $args 1 end]
    set path {}
    if {[llength $args] % 2} {
      set path [lindex $args 0]
      set args [lrange $args 1 end]
    }
    set options [::tclpdf::option parse {type auto data {} icc 1 stencil 0 \
        mask {} interpolate 0 invert 0} $args "image embed"]
    foreach name {icc stencil interpolate invert} {
      if {![string is boolean -strict [dict get $options $name]]} {
        return -code error "tclpdf: -$name of image embed takes a boolean, not\
            \"[dict get $options $name]\""
      }
    }
    set images [my state images]
    if {[dict exists $images $alias]} {
      return -code error "tclpdf: an image named \"$alias\" is already embedded"
    }
    if {$path ne {}} {
      set bytes [::tclpdf::io read $path]
    } elseif {[dict get $options data] ne {}} {
      set bytes [dict get $options data]
    } else {
      return -code error "tclpdf: image embed needs a file name or -data"
    }
    set type [dict get $options type]
    if {$type eq "auto"} {
      set type [my ImageType $bytes $path]
    }
    switch -- $type {
      jpeg {set parsed [::tclpdf::imageJpeg parse $bytes]}
      png {set parsed [::tclpdf::imagePng parse $bytes]}
      tiff {set parsed [::tclpdf::imageTiff parse $bytes]}
      default {
        return -code error "tclpdf: unknown image type \"$type\" - known are:\
            auto, jpeg, png, tiff"
      }
    }
    # -stencil turns the picture into an image mask (8.9.6.2): what reaches
    # the page is not the picture but the current fill colour, through the
    # bits that are set. Decided HERE, at the embedding, because it decides
    # what the XObject IS - a stencil has no colour space, so it cannot be
    # made one at a placement. [stencilInk] refuses whatever cannot be one
    # bit per sample and reports why; JPEG and TIFF are refused before it,
    # each with its own reason.
    if {[dict get $options stencil]} {
      if {$type eq "jpeg"} {
        return -code error "tclpdf: a stencil mask is one bit per sample (ISO\
            32000-2, Table 87: with ImageMask true BitsPerComponent shall be\
            1), and a DCTDecode filter always delivers 8-bit samples (Table\
            87) - a stencil has to be a 1-bit PNG, not a JPEG"
      }
      if {$type eq "tiff"} {
        # Not a rule of the format - a bilevel TIFF is one bit per sample and
        # could be a stencil. It is a rule of this package: a striped TIFF
        # reaches the file as SEVERAL XObjects (see [ImageStack]), and a
        # /Mask entry names exactly one; and the polarity of a bilevel TIFF
        # travels as Photometric or as BlackIs1 rather than as the ink
        # [stencilInk] picks out of a palette. Saying so is cheaper than a
        # stencil that is right for one file and inverted for the next.
        return -code error -errorcode {TCLPDF TIFF STENCIL} \
            "tclpdf: -stencil 1 makes an image mask out of a\
            ONE-BIT PNG, and \"$alias\" is a TIFF - a striped TIFF becomes\
            several stacked XObjects and a Mask entry names one image (ISO\
            32000-2, 8.9.6.3); convert it to a 1-bit PNG for a stencil, or\
            place it as the picture it is"
      }
      ::tclpdf::imagePng stencilInk $parsed
      # An image mask has no ColorSpace entry at all (Table 87: "shall not be
      # specified"), so a profile in the file has nothing to anchor and is
      # left behind rather than refused - [image info] reports icc 0 for it.
      dict set parsed icc {}
    } elseif {[dict get $options invert]} {
      # Outside a stencil the reversal is a Decode array over the samples,
      # and Table 87 fixes its length at twice the number of components: two
      # numbers exist only for a one-component picture. That is the picture
      # a soft mask is made of, which is what this is for.
      if {[my ImageDevice $type $parsed] ne "DeviceGray"} {
        return -code error "tclpdf: -invert reverses a picture of ONE\
            component - a stencil mask or a greyscale picture - and\
            \"$alias\" is [my ImageDevice $type $parsed]; a Decode array is\
            twice as long as the picture has components (ISO 32000-2, Table\
            87)"
      }
    }
    # -mask names a SECOND embedded picture as this one's mask. Which of the
    # two masking mechanisms that is depends on what the named picture is,
    # and the difference is not a detail of syntax: a stencil mask is
    # all-or-nothing and becomes /Mask (8.9.6.3, explicit masking), a
    # greyscale picture is coverage and becomes /SMask (11.6.5.2, soft-mask
    # images). The refusals below are Table 143, which says what a soft-mask
    # image may be: DeviceGray, and neither masked nor soft-masked itself.
    if {[dict get $options mask] ne {}} {
      set maskAlias [dict get $options mask]
      if {![dict exists $images $maskAlias]} {
        return -code error "tclpdf: -mask of image embed names no embedded\
            image \"$maskAlias\" - known are: [join [dict keys $images] {, }];\
            the mask has to be embedded before the picture that wears it"
      }
      if {[dict get $options stencil]} {
        return -code error "tclpdf: \"$alias\" is a stencil mask and cannot\
            wear a mask of its own - with ImageMask true the Mask entry shall\
            not be present (ISO 32000-2, Table 87), and a stencil has no\
            colour for a soft mask to cover"
      }
      # Only a PNG can arrive with transparency of its own: a JPEG has none,
      # and a TIFF that has any is an ExtraSamples file, which imageTiff
      # refuses by name at the parse above - PDF carries no alpha inside an
      # image and this package splits none out.
      if {$type eq "png" && ([::tclpdf::imagePng hasAlpha $parsed]
          || [::tclpdf::imagePng transparency $parsed] ne "none")} {
        return -code error "tclpdf: \"$alias\" carries its own transparency\
            and already reaches the file with a mask on it - a second one\
            would replace it (ISO 32000-2, Table 87: an SMask entry overrides\
            the image's Mask entry); mask a picture that has none, or leave\
            the one it brought"
      }
      my ImageMaskCheck $maskAlias [dict get $images $maskAlias]
    }
    # An embedded ICC profile (JPEG APP2, PNG iCCP) becomes the picture's
    # /ICCBased colour space instead of the bare device space - unless
    # -icc 0 says to leave it behind. A kept profile is held to what
    # 8.6.5.5 requires of it HERE, before anything is recorded: it has to
    # be a profile at all, and it has to describe the space the samples
    # are in - an /N that contradicts the data is a picture no reader
    # renders predictably.
    if {[dict get $parsed icc] ne {}} {
      if {![dict get $options icc]} {
        dict set parsed icc {}
      } else {
        set source [expr {$path ne {} ? "\"$path\"" : "the picture data"}]
        if {[catch {my IccInspect [dict get $parsed icc] \
            "the ICC profile in $source"} inspected]} {
          return -code error "$inspected - the picture itself is fine;\
              -icc 0 embeds it without the profile"
        }
        lassign $inspected profileSpace profileComponents
        set device [my ImageDevice $type $parsed]
        if {$profileSpace ne [dict get \
            {DeviceGray GRAY DeviceRGB RGB DeviceCMYK CMYK} $device]} {
          return -code error "tclpdf: the ICC profile in $source describes\
              $profileSpace, but the picture's samples are in $device - the\
              profile of an image colour space has to describe that space\
              (ISO 32000-1, 8.6.5.5); -icc 0 embeds the picture without it"
        }
        dict set parsed iccComponents $profileComponents
      }
    }
    dict set images $alias [dict create type $type parsed $parsed \
        bytes $bytes path $path object {} \
        stencil [expr {[dict get $options stencil] ? 1 : 0}] \
        mask [dict get $options mask] \
        interpolate [expr {[dict get $options interpolate] ? 1 : 0}] \
        invert [expr {[dict get $options invert] ? 1 : 0}]]
    my state images $images
    return $alias
  }

  # The device colour space a picture's samples are in - DeviceGray, DeviceRGB
  # or DeviceCMYK - whichever of the two formats it is. Two callers ask, the
  # profile check and the mask check, and a second copy of the [expr] is how
  # they would come to disagree about a palette PNG.
  method ImageDevice {type parsed} {
    switch -- $type {
      jpeg {return [::tclpdf::imageJpeg space [dict get $parsed components]]}
      tiff {return [::tclpdf::imageTiff device $parsed]}
    }
    return [::tclpdf::imagePng device $parsed]
  }

  # The same question one step out, and the one [image info] answers: the
  # space of the SAMPLES, with a palette called a palette instead of being
  # resolved to the space its entries are in. [ImageDevice] deliberately
  # resolves it - the profile check and the mask check both ask what the
  # numbers mean, and an /Indexed picture's numbers are RGB - while a caller
  # laying out around a picture is being told what the file holds.
  method ImageSpaceName {image} {
    if {[dict get $image stencil]} {
      return {}
    }
    set parsed [dict get $image parsed]
    switch -- [dict get $image type] {
      png {
        return [expr {[dict get $parsed colorType] == 3 ? "Indexed"
            : [::tclpdf::imagePng device $parsed]}]
      }
      tiff {return [dict get $parsed space]}
    }
    return [::tclpdf::imageJpeg space [dict get $parsed components]]
  }

  # May this embedded picture serve as another one's mask?
  #
  # A stencil may always: it becomes /Mask and is the very thing 8.9.6.3
  # asks for, "an image mask, as described in 8.9.6.2, which serves as an
  # explicit mask for the primary (base) image".
  #
  # Anything else becomes /SMask, and Table 143 lists what a soft-mask image
  # dictionary may hold: ColorSpace "Required; shall be DeviceGray", Mask
  # "shall be absent", SMask "shall be absent". Each of the three is a way a
  # picture can fail here, and each is refused with the way out rather than
  # with the clause alone - an RGB picture is the caller's mistake, a grey
  # picture with a profile or with transparency of its own is one step from
  # being usable.
  method ImageMaskCheck {alias image} {
    if {[dict get $image stencil]} {
      return
    }
    set parsed [dict get $image parsed]
    set device [my ImageDevice [dict get $image type] $parsed]
    if {$device ne "DeviceGray"} {
      return -code error "tclpdf: \"$alias\" is a $device picture and cannot\
          be a soft mask - the colour space of a soft-mask image shall be\
          DeviceGray (ISO 32000-2, Table 143), because a mask is coverage\
          rather than colour; embed it as a greyscale picture, or with\
          -stencil 1 if it is one bit per sample"
    }
    if {[dict get $parsed icc] ne {}} {
      return -code error "tclpdf: \"$alias\" carries an ICC profile, so its\
          colour space would be /ICCBased, and a soft-mask image shall be\
          DeviceGray (ISO 32000-2, Table 143) - embed the mask with -icc 0"
    }
    # The same clause, and the entry the transparency check below cannot
    # see: a picture EMBEDDED WITH -mask reaches the file wearing an /SMask
    # or a /Mask of its own, whatever format it is, and Table 143 has both
    # absent in a soft-mask image. The check below asks the PNG bytes what
    # transparency the file brought; this one asks what the caller put on
    # top. Measured on 2026-08-22, before this stood here: a JPEG embedded
    # with -mask became another picture's soft mask without a word, and the
    # mask of a mask is a dictionary entry no reader is required to follow.
    if {[dict get $image mask] ne {}} {
      return -code error "tclpdf: \"$alias\" was embedded with a mask of its\
          own (-mask [dict get $image mask]), so it reaches the file with a\
          Mask or an SMask entry - and in a soft-mask image both shall be\
          absent (ISO 32000-2, Table 143); embed the picture a second time\
          without -mask to use it as a mask, or mask with a picture that\
          wears none"
    }
    # A TIFF is not asked about transparency: it cannot carry any of its own
    # (an ExtraSamples file is refused at the parse). What it CAN be is a stack
    # of XObjects, and a soft mask is one image - that is refused where the
    # stack becomes known, in [TiffStreams], before anything is written.
    if {[dict get $image type] eq "png"
        && ([::tclpdf::imagePng hasAlpha $parsed]
            || [::tclpdf::imagePng transparency $parsed] ne "none")} {
      return -code error "tclpdf: \"$alias\" has transparency of its own, so\
          it would reach the file with a mask on it - and in a soft-mask\
          image Mask and SMask shall both be absent (ISO 32000-2, Table 143);\
          a mask says how much of the picture shows and needs no transparency\
          besides"
    }
    return
  }

  # Which format is this? Decided by the magic bytes, not by the file name -
  # a ".jpg" that is really a PNG is common enough to be worth not trusting.
  #
  # Which is also why an image passed as bytes needs no name to be identified:
  # the name never decided anything. It only has to be SAID differently when
  # the refusal is reported, since there is no file to point at.
  method ImageType {bytes path} {
    if {[string range $bytes 0 7] eq "\x89PNG\r\n\x1a\n"} {
      return png
    }
    binary scan [string range $bytes 0 1] cucu first second
    if {$first == 0xff && $second == 0xd8} {
      return jpeg
    }
    # Both byte orders, and BigTIFF too - which [signature] answers for on
    # purpose, so that [parse] can refuse it as the BigTIFF it is rather than
    # this line calling it "not a picture". Measured over 197 files named
    # .tif or .tiff: one is a JPEG and two are mail text, which is why the
    # order here is bytes first and never the name.
    if {[::tclpdf::imageTiff signature $bytes] ne {}} {
      return tiff
    }
    set what [expr {$path ne {} ? "\"$path\"" :
        "the data passed with -data ([string length $bytes] bytes)"}]
    return -code error "tclpdf: $what is neither a JPEG, a PNG nor a TIFF -\
        tclpdf writes those three formats"
  }

  method ImagePlace {alias args} {
    set options [::tclpdf::option parse {
      at {} size {} width {} height {} scale {} rotate 0 opacity {} dpi {}
      fit {} fitMode {} align left valign top
      alt {} artifact {} inline 0
    } $args "image place"]
    set images [my state images]
    if {![dict exists $images $alias]} {
      return -code error "tclpdf: no image named \"$alias\" - known are:\
          [join [dict keys $images] {, }]"
    }
    set image [dict get $images $alias]
    # Every value is checked BEFORE the picture's object goes out, before
    # its colour space is recorded and before the mark and the "q" are
    # written: -at, -rotate, the sizes and -dpi (in ImageExtent), -alt
    # against -artifact, and the alpha last, since that one makes its
    # ExtGState as it passes. Measured before 2026-08-18: "-rotate x" was
    # read after [save] and left the mark and the q open, "-dpi 0" went
    # out as Inf, "-at {a b}" left a colour space record for a picture that
    # never reached the page, and every one of them had already written the
    # image object into the file.
    if {[dict get $options at] ne {}} {
      my GraphicsPoint [dict get $options at] -at "image place"
    }
    lassign [expr {[dict get $options at] eq {} ? {0 0} : [dict get $options at]}] left top
    if {![string is double -strict [dict get $options rotate]]} {
      return -code error "tclpdf: -rotate of image place is an angle in\
          degrees, not \"[dict get $options rotate]\""
    }
    lassign [my ImageExtent $image $options "image place"] width height
    # AND LARGE ENOUGH TO BE WRITTEN. [checkFit] held -size, -scale and -dpi
    # above zero, which is the caller's number; this holds the number that
    # reaches the FILE. A PDF real carries five decimals (7.3.3), so a
    # placement below 0.00001 pt on either axis goes out as "0 0 0 0 x y cm"
    # - a matrix that collapses the page onto a point, with the "Do" of the
    # picture under it. Measured on 2026-08-25: "-fit {0.0000001 0.0000001}"
    # wrote exactly that, and qpdf, veraPDF and poppler all took the file
    # without a word. Same reasoning as [::tclpdf::geometry check], and the
    # same [singular] does the judging - see there.
    if {[::tclpdf::geometry singular \
        [list [my distance $width] 0 0 [my distance $height] 0 0]]} {
      return -code error "tclpdf: \"$alias\" comes out $width by $height\
          [my cget -unit] here, which is below the 0.00001 pt a PDF real\
          holds (7.3.3) - the placement would be written as \"0 0 0 0 x y\
          cm\", a matrix that collapses onto a point, and nothing of the\
          picture would reach the page; give it a size a reader can show"
    }
    # -at names the top left corner of the BOX, exactly as it names the top
    # left corner of a [rect]; -align and -valign then say where in that box
    # the picture sits. Without -fit the box has no size, and the same sum is
    # the plain anchor: -align right puts the picture's right edge on the x
    # that was given. The arithmetic is [fitAnchor] in page.tcl, shared so
    # that an anchor and an anchor inside a box cannot come apart.
    #
    # A COVERED BOX IS CUT BACK TO THE BOX. -fitMode cover scales the picture
    # until both edges are covered, which leaves it hanging over the box on
    # one axis - the box is what the caller asked to see, so the overhang is
    # clipped away rather than drawn across whatever stands beside it. The
    # rectangle is the one -at and -fit name, before the anchor moved the
    # picture inside it.
    set clip {}
    if {[dict get $options fit] ne {}
        && [dict get $options fitMode] eq "cover"} {
      set clip [list $left $top {*}[dict get $options fit]]
    }
    lassign [my fitAnchor [list $left $top] $width $height $options] left top
    my GraphicCheck image "image place" [dict get $options alt] \
        [dict get $options artifact]
    # The one option value in this module that carries a code of its own, and
    # it earns it: a caller who traps {TCLPDF IMAGE INLINE} to fall back on an
    # XObject wants the mistyped boolean in that class too, rather than as the
    # single bare error left in the way.
    if {![string is boolean -strict [dict get $options inline]]} {
      return -code error -errorcode [list TCLPDF IMAGE INLINE BOOLEAN \
          [dict get $options inline]] \
          "tclpdf: -inline of image place takes a boolean, not\
          \"[dict get $options inline]\""
    }
    set inline [expr {[dict get $options inline] ? 1 : 0}]
    # The picture written INTO the stream (8.9.7) rather than beside it. Built
    # HERE, before the ExtGState of -opacity is made and before the first
    # resource is touched, because every refusal an inline image can make -
    # the 4096 bytes, a mask, a profile, a stack - has to leave the document
    # exactly as it was. It creates no object and takes no resource name, so
    # a picture placed inline five times travels five times: that is what the
    # caller asked for, and it is why -inline is asked for rather than
    # decided here.
    set inlineText {}
    set space {}
    if {$inline} {
      lassign [my ImageInline $alias $image] inlineText space
    }
    set alpha {}
    if {[dict get $options opacity] ne {}} {
      set alpha [my GraphicsOpacity [dict get $options opacity]]
    }
    # Asked of the RESOURCE, not of the object: a picture serving as another
    # one's mask already has an object and no resource name, and reading the
    # object alone left [ImagePlace] naming a resource the page never got.
    if {!$inline} {
      if {![dict exists $image resource]} {
        # ImageWrite registers the resource in the state itself, so the local
        # copy has to be refreshed - not doing so is how a place ends up naming
        # a resource that the dictionary already has.
        my ImageWrite $alias $image
        set image [dict get [my state images] $alias]
      }
      set space [dict get $image space]
    }

    # A picture's colour space counts like a painted colour for the PDF/A
    # intent check (ISO 19005-2, 6.2.4.3 - measured with veraPDF, a DeviceRGB
    # picture fails under a CMYK intent, a DeviceCMYK JPEG under sRGB).
    # Recorded per PLACEMENT, not once at ImageWrite: the record names the
    # page, and the object is written on the first page the picture appears
    # on, which may not be the one a caller looks at. And recorded here,
    # after the last value that can be refused, so that a placement that
    # never happened leaves no record. A soft mask is DeviceGray, which
    # every intent admits, and is not recorded. Nor is a stencil mask, which
    # has no colour space at all (Table 87: with ImageMask true ColorSpace
    # "shall not be specified") - what it paints is the fill colour, and that
    # was recorded when the colour was set.
    if {$space ne {}} {
      my ColourSpaceUsed $space "image place"
    }

    # A picture XObject is a unit square with its origin at the BOTTOM left, so
    # the matrix carries both the size and the flip to the top-left convention
    # every other method here uses.
    lassign [my coords $left [expr {$top + $height}]] x y
    set w [my distance $width]
    set h [my distance $height]

    # In a tagged document a picture is either a Figure with a description or
    # an artifact, and there is no third answer: a Figure without Alt fails
    # validation, and an untagged picture is content belonging to no element.
    #
    # Artifact is the default because it is the honest one. A logo, a rule, a
    # background carries nothing a reader needs to hear, and that is most of
    # what a picture in a document is. -alt turns it into a Figure and is the
    # caller saying this one means something - which is a judgement no writer
    # can make for them.
    #
    # -artifact 1 is the same judgement the other way round: this one is
    # decoration, and meant to be. The default artifact is what a picture
    # becomes when NOBODY judged, and that is the one case that has to be
    # remembered - see [undescribedGraphics] below.
    #
    # The matrix is built BEFORE the mark, because the Figure's box is read
    # off it. Only arithmetic moved up here - everything that can be refused
    # was decided further above, so nothing is written before its check.
    set matrix [::tclpdf::geometry multiply \
        [list $w 0 0 $h 0 0] [::tclpdf::geometry translate $x $y]]
    if {[dict get $options rotate] != 0} {
      # Rotate about the placement corner, not about the origin of the page -
      # otherwise a rotated picture leaves the sheet, which is exactly the
      # defect the -at handling in graphics.tcl was fixed for.
      set matrix [::tclpdf::geometry multiply \
          [list $w 0 0 $h 0 0] [::tclpdf::geometry multiply \
              [::tclpdf::geometry rotate [dict get $options rotate]] \
              [::tclpdf::geometry translate $x $y]]]
    }

    # The bounding box goes with the Figure. Not required by the letter of
    # the standard, but the Best Practice Guide names it as what the reading
    # tools rely on to find a figure on the page.
    #
    # It is read off the MATRIX rather than off -at and -width, and an image
    # XObject is the unit square, so those are the corners that go through it.
    # Measured on 2026-08-21, before this was so: a picture placed with
    # -rotate 30 declared a box that left ink outside it on two sides and
    # claimed page on a third - 14.8.5.4.3 asks for the rectangle that
    # completely encloses the visible content. Without a rotation the answer
    # is the placement rectangle, as before.
    lassign [my GraphicMark image "image place" [dict get $options alt] \
        [dict get $options artifact] $top [my PlacedBox 1 1 $matrix $clip]] \
        mark element
    my save
    # Inside the q, so the enclosing Q takes it back again: a clipping path
    # holds until the graphics state it was set in is restored (8.5.4), and
    # one left standing would cut everything drawn on the page after the
    # picture. Before the "cm" because it is stated in the page's own
    # coordinates, not in the picture's unit square.
    if {$clip ne {}} {
      my clip -at [lrange $clip 0 1] -size [lrange $clip 2 3]
    }
    if {$alpha ne {}} {
      my content "[::tclpdf::pdfObj name $alpha] gs\n"
    }
    if {!$inline && [dict exists $image parts]} {
      # A stack carries the matrix into every part and writes its own "cm"
      # for each of them, which is why the one below is not written here.
      my ImageStack $image $matrix
    } else {
      my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
      # An inline image is drawn on the same unit square an image XObject is
      # drawn on (8.9.5), so the matrix carries the size, the flip and the
      # rotation exactly as it does for a "Do" - the two differ in where the
      # bytes are, not in how the picture is placed.
      if {$inline} {
        my content $inlineText
      } else {
        my content "[::tclpdf::pdfObj name [dict get $image resource]] Do\n"
      }
    }
    my restore
    my GraphicUnmark $mark $element
    return $alias
  }

  # A picture that is several images, put back together on the page.
  #
  # This is the whole of decision (a): n cm/Do pairs, each in a q ... Q of
  # its own, inside the ONE q ... Q the placement already opened - and no
  # form XObject around them. The stack stays where it is used, which is
  # where it belongs: 80 of 194 measured files are single-stripped and both
  # real scans have one strip per page, so a stack is the exception. The
  # price of the other way would have been paid by every picture: a form
  # XObject cannot be another image's /SMask.
  #
  # Each part is an image on the unit square like any other (8.9.5), so the
  # arithmetic is done in the PICTURE's unit square and then handed to the
  # matrix that put the picture on the page. That is what makes -rotate,
  # -scale and the flip to the top-left convention come out right for a
  # stack without a second copy of any of it: the parts know nothing about
  # the page.
  #
  #   fraction  how much of the picture's height this part is
  #   offset    how far its BOTTOM edge sits above the picture's bottom -
  #             the rows are counted from the top and y runs up, so the two
  #             are each other's complement
  #
  # A q of its own per part, because "cm" concatenates: without it the second
  # part would be placed inside the first part's coordinates, and the third
  # inside the second's.
  method ImageStack {image matrix} {
    set rows [dict get [dict get $image parsed] height]
    foreach part [dict get $image parts] {
      set fraction [expr {double([dict get $part rows]) / $rows}]
      set offset [expr {1.0
          - double([dict get $part row] + [dict get $part rows]) / $rows}]
      set placement [::tclpdf::geometry multiply \
          [list 1 0 0 $fraction 0 $offset] $matrix]
      my save
      my content "[join [lmap number $placement {
          ::tclpdf::pdfObj num $number}] { }] cm\n"
      my content "[::tclpdf::pdfObj name [dict get $part resource]] Do\n"
      my restore
    }
    return
  }

  # A picture written into the content stream (8.9.7): BI, an abbreviated
  # dictionary, ID, the bytes, EI. Answers {text space} - the operators to
  # append where a "Do" would otherwise stand, and the colour space of the
  # samples for the PDF/A intent check.
  #
  # NOTHING is written and no object is created, so every refusal below leaves
  # the document exactly as it was - which is the reason the version floor is
  # raised last, after the byte count has been weighed: a picture that is
  # refused must not pin the file to PDF 1.5 on its way out.
  method ImageInline {alias image} {
    lassign [my ImageInlineStreams $alias $image] pairs data space version
    set limit $::tclpdf::image::inlineLimit
    set size [string length $data]
    if {$size > $limit} {
      return -code error \
          -errorcode [list TCLPDF IMAGE INLINE SIZE $size $limit] \
          "tclpdf: \"$alias\" carries $size bytes of image data, and ISO\
          32000-2, 8.9.7 says an inline image should be used only for small\
          images ($limit bytes or less) - tclpdf holds to that line rather\
          than writing a picture the standard advises against; leave -inline\
          off and it goes into the file as an image XObject, which has no\
          such limit and is the cheaper way in for anything this size anyway"
    }
    # The PDF/A question, asked but NOT recorded: the record belongs to a
    # picture that goes down, and the version floor below is raised for one
    # too. See [ImageInterpolateCheck].
    my ImageInterpolateCheck $image $alias
    if {$version ne {}} {
      my RequireVersion {*}$version
    }
    # /L is PDF 2.0, and in a 2.0 file 8.9.7 says it "shall be present on all
    # inline images" (Table 91): the length of the data between ID and EI,
    # excluding the white space that delimits them. In a 1.x file it is
    # written NOT AT ALL - the key did not exist, and Note 1 of that clause
    # says a processor will not encounter it there.
    #
    # ASKED OF THE WRITER AT THIS MOMENT, WHICH IS WHEN THE PICTURE IS
    # WRITTEN - and that is only half an answer, because the version can
    # still be RAISED afterwards. Measured on 2026-08-25: "-version 1.7", an
    # inline picture, then "configure -version 2.0" gave a file whose header
    # says %PDF-2.0 and which contains no /L anywhere, against the promise
    # the manual makes. The bytes are in the content stream by then and
    # nothing can put an entry into a dictionary that has already been
    # written.
    #
    # So the 1.x file is BOUND to 1.x, the same way a PDF/A claim binds it
    # (see [limit] in writer.tcl): the picture is a fact about the file, and
    # a fact that only holds below 2.0 is a ceiling. A caller who wants both
    # creates the document as 2.0, and then the entry is written here.
    if {[package vcompare [[my writer] version] 2.0] >= 0} {
      lappend pairs Length $size
      # And the same fact the other way round: the entry is in the stream, so
      # the file cannot be lowered under it either. Both halves are needed -
      # a ceiling alone would still let "-version 2.0, inline picture,
      # configure -version 1.7" write /L into a file whose header disowns it.
      my RequireVersion 2.0 "an inline image with the /L that PDF 2.0 requires\
          of one (ISO 32000-2, 8.9.7)"
    } else {
      my LimitVersion 1.7 "an inline image drawn without the /L that PDF 2.0\
          requires of one (ISO 32000-2, 8.9.7)"
    }
    # Nothing below this line can refuse the picture any more, so this is
    # where the record goes down - see [ImageInterpolateEntry].
    lappend pairs {*}[my ImageInterpolateEntry $image $alias]
    set text "BI\n"
    # Each entry is built as ONE string and the strings are joined. Handing
    # [join] a list of two-element pairs instead puts Tcl's own braces round
    # any value that holds a space - the /DP dictionary of a PNG does - and
    # a brace is PDF syntax for nothing at all.
    set entries {}
    foreach {key value} [::tclpdf::image::inlinePairs $pairs] {
      lappend entries "/$key $value"
    }
    append text [join $entries { }]
    # "ID shall be followed by a single white-space character, and the next
    # character shall be interpreted as the first byte of image data"
    # (8.9.7) - so exactly one space here, whatever the filter is, and the
    # EI preceded by one, so that it cannot run into the last data byte.
    append text "\nID " $data "\nEI\n"
    return [list $text $space]
  }

  # The dictionary and the data of an inline picture, and what an inline
  # picture cannot be. Answers {pairs data space version}, with pairs under
  # their FULL names - [inlinePairs] abbreviates them, and holding them
  # against Table 92 there rather than here is what keeps the two halves from
  # drifting apart.
  #
  # The three format branches are the ones [ImageObject] takes, minus
  # everything the refusals above have already cut away: no profile, no mask,
  # no stack, and therefore no object to create on the way. What is left is
  # which reader to ask, and the readers are the same ones - a picture does
  # not become a different picture for being written in a different place.
  #
  # Five things an inline image cannot be, each refused by name:
  #
  #   masked              /Mask and /SMask are not in Table 91, and an SMask
  #                       is an indirect reference besides, which a content
  #                       stream shall not contain (7.8.2)
  #   transparent         the same entry from the other side: a picture that
  #                       brings an alpha channel, a transparent colour or a
  #                       partly transparent palette needs one of them
  #   ICC tagged          /ICCBased is an array naming a stream object - the
  #                       same indirect reference, for the same reason
  #   a stack             a striped TIFF is several images and BI ... EI is
  #                       one
  #   over the limit      weighed in [ImageInline], where the bytes are known
  method ImageInlineStreams {alias image} {
    set type [dict get $image type]
    set parsed [dict get $image parsed]
    if {[dict get $image mask] ne {}} {
      return -code error -errorcode {TCLPDF IMAGE INLINE MASK} \
          "tclpdf: \"$alias\" wears -mask \"[dict get $image mask]\", and\
          a mask is a second image named by an entry an inline image object\
          has no room for - ISO 32000-2, Table 91 lists what it holds and\
          8.9.7 says entries other than those shall be IGNORED, so a Mask\
          written into one would not be a mask, it would be nothing; a soft\
          mask would be an indirect reference besides, which a content stream\
          shall not contain (7.8.2). Leave -inline off and the picture goes\
          into the file as an image XObject, mask and all"
    }
    if {[dict get $parsed icc] ne {}} {
      return -code error -errorcode {TCLPDF IMAGE INLINE ICC} \
          "tclpdf: \"$alias\" travels with an ICC profile, so its colour\
          space is /ICCBased - and the colour space of an inline image shall\
          not be a CIE-based one (ISO 32000-2, 8.9.7); it would be an\
          indirect reference into the bargain, which a content stream shall\
          not contain (7.8.2). Embed it with -icc 0 to write it inline in its\
          device colour space, or leave -inline off and the profile travels\
          with it"
    }
    if {$type eq "png" && ![dict get $image stencil]} {
      set way [expr {[::tclpdf::imagePng hasAlpha $parsed] ? "alpha"
          : [::tclpdf::imagePng transparency $parsed]}]
      if {$way ne "none"} {
        return -code error -errorcode [list TCLPDF IMAGE INLINE MASK $way] \
            "tclpdf: \"$alias\" carries transparency of its own ([dict get\
            {alpha {an alpha channel} colourKey {a transparent colour}\
            softMask {a partly transparent palette}} $way]), so it reaches\
            the file with a Mask or an SMask entry - and an inline image\
            object holds neither, so it would be ignored rather than carried\
            (ISO 32000-2, Table 91 and 8.9.7); leave -inline off, or embed a\
            picture without transparency"
      }
    }
    set pairs [list Width [dict get $parsed width] \
        Height [dict get $parsed height]]
    set version {}
    if {[dict get $image stencil]} {
      # The classic inline image, and the one this is worth having for: a
      # one-bit stamp of a few dozen bytes, painted in the fill colour. It
      # has no colour space at all (Table 87), so there is none to record.
      set streams [::tclpdf::imagePng stencilStreams $parsed \
          [dict get $image invert]]
      lappend pairs {*}[dict get $streams pairs]
      set data [dict get $streams data]
      set space {}
    } elseif {$type eq "jpeg"} {
      set space [::tclpdf::imageJpeg space [dict get $parsed components]]
      lappend pairs ColorSpace /$space \
          BitsPerComponent [dict get $parsed bitsPerComponent] \
          Filter /DCTDecode
      if {[::tclpdf::imageJpeg inverted $parsed]} {
        lappend pairs Decode [::tclpdf::pdfObj arr {1 0 1 0 1 0 1 0}]
      }
      set data [dict get $image bytes]
    } elseif {$type eq "tiff"} {
      set parsed [my TiffInvert $parsed [dict get $image invert]]
      set parts [dict get [::tclpdf::imageTiffStreams streams \
          [dict get $image bytes] $parsed] parts]
      if {[llength $parts] > 1} {
        return -code error -errorcode {TCLPDF IMAGE INLINE STACKED} \
            "tclpdf: [my TiffStackIs $alias $parsed], and BI ... ID ... EI\
            is ONE image (ISO 32000-2, 8.9.7) - [my TiffStackFix $parsed], or\
            leave -inline off and the parts go into the file as the image\
            XObjects they are"
      }
      set space [::tclpdf::imageTiff device $parsed]
      # The lookup string of a palette goes in through pdfObj rather than
      # through [BytesStr]: a string inside a content stream is NOT encrypted
      # on its own, the stream it sits in is (ISO 32000-2, 7.6.2), and a
      # doubly encrypted palette is a picture in the wrong colours.
      lappend pairs ColorSpace \
          [my TiffSpace $parsed /$space {::tclpdf::pdfObj bytesStr}] \
          BitsPerComponent [dict get $parsed bitsPerComponent]
      lappend pairs {*}[dict get [lindex $parts 0] pairs]
      set data [dict get [lindex $parts 0] data]
      if {[dict get $parsed bitsPerComponent] == 16} {
        set version {1.5 "a 16-bit TIFF picture"}
      }
    } else {
      # Same reason as the TIFF palette above - the default bytesStr of
      # [streams] is pdfObj's, so this is the call that does NOT hand the
      # document's encrypting one in.
      set streams [::tclpdf::imagePng streams $parsed]
      lappend pairs {*}[dict get $streams pairs]
      set data [dict get $streams data]
      set space [::tclpdf::imagePng device $parsed]
      if {[dict get $parsed bitDepth] == 16} {
        set version {1.5 "a 16-bit PNG picture"}
      }
    }
    if {![dict get $image stencil] && [dict get $image invert]
        && $type ne "tiff"} {
      lappend pairs Decode [::tclpdf::pdfObj arr {1 0}]
    }
    return [list $pairs $data $space $version]
  }

  # Whether /Interpolate is written, and the one place that decides it.
  #
  # A HINT AND NOTHING MORE, on the PDF side: 8.9.5.3 says it "is a way for a
  # PDF to declare to a PDF processor that a specific image might render
  # better if interpolation is used", and that a processor "may ignore it".
  # Only written where it was asked for - Table 87 gives it the default
  # false, and a dictionary that repeats a default says nothing.
  #
  # UNDER PDF/A IT IS NOT A HINT BUT A VIOLATION. ISO 19005-2, 6.2.8 and
  # ISO 19005-3 with it: "The Interpolate key shall not be present, or shall
  # have a value of false" - and veraPDF reports it. Until 2026-08-24 this
  # package wrote it anyway, in both places, so a document could claim PDF/A,
  # pass its own checks and fail an external validator on a key the caller
  # had asked for in good faith.
  #
  # ASKED ON BOTH ROADS, AND NEITHER CAN WAIT FOR THE WRITE. An inline
  # picture's dictionary goes into the content stream as it is drawn, and an
  # image XObject is built on FIRST PLACEMENT rather than at write time - a
  # first draft of this refused only at the write, on the reasoning that a
  # document declares PDF/A and embeds its pictures in either order, and
  # measured on 2026-08-24 it let "place, then pdfa" through untouched.
  #
  # So the question is asked when the picture goes down, and what went down
  # is remembered: [pdfa] asks the other way round for a picture already
  # drawn. Between the two, both orders are covered and neither road writes
  # a key the other has learnt to refuse.
  # THE QUESTION AND THE RECORD ARE TWO CALLS, and the order they are made in
  # is the whole of it. [ImageInterpolateCheck] refuses and remembers
  # NOTHING, so it can be asked before the first byte is written;
  # [ImageInterpolateEntry] remembers and answers the dictionary entry, so it
  # is asked last, when the picture is certain to go down. Between them sit
  # every other refusal each road still has to make.
  #
  # Measured on 2026-08-25, when the two were one call: an inline picture
  # over the 4096-byte line was recorded as interpolated BEFORE that line was
  # weighed, so a refused picture - one that never reached the file - locked
  # the document out of [pdfa] afterwards, with a message ("the picture is in
  # the file by now and cannot be taken back") that was not true and left the
  # caller no way back. And on the XObject road the refusal came AFTER the
  # soft mask had been written: 2503 bytes of alpha channel stayed in the
  # file with nothing pointing at them, which qpdf --qdf drops and qpdf
  # --check and veraPDF do not mention.
  method ImageInterpolateCheck {image what} {
    if {![dict get $image interpolate] || [my state pdfa] eq {}} {
      return
    }
    return -code error -errorcode [list TCLPDF IMAGE INTERPOLATE PDFA $what] \
        "tclpdf: \"$what\" was embedded with -interpolate 1 and this\
        document claims PDF/A-[dict get [my state pdfa] part][dict get \
        [my state pdfa] conformance], where ISO 19005-2, 6.2.8 says the\
        Interpolate key shall not be present or shall be false - drop\
        -interpolate, or drop the pdfa declaration. Smoothing is the\
        reader's decision to make, and an archive format takes it away on\
        purpose: the same file has to look the same in twenty years"
  }

  method ImageInterpolateEntry {image what} {
    if {![dict get $image interpolate]} {
      return {}
    }
    # The refusal again, in case a road ever reaches here without having
    # asked: the two questions have to give one answer, and asking twice
    # costs a dict lookup.
    my ImageInterpolateCheck $image $what
    # Remembered only now: what the declaration has to know is that the
    # picture WENT DOWN asking for interpolation, and a picture that was
    # refused did not.
    my state imageInterpolated \
        [lsort -unique [concat [my state imageInterpolated] [list $what]]]
    return [list Interpolate true]
  }

  # The marking every placed graphic gets, in one place: a picture, a drawing
  # and a form invocation are all one piece of content, and in a tagged
  # document each is either a Figure with a description or an artifact -
  # there is no third answer. Written once here rather than in each of the
  # three modules, because the three copies had already begun to differ.
  #
  # kind is image, svg or form and names the entry in [undescribedGraphics];
  # context is the call for the error messages ("image place"); top is where
  # the content begins, for [StructureMark]; bbox is the Figure's bounding
  # box, which only a picture knows well enough to give.
  #
  # Answers {mark element}: the mark for [StructureBegin] and the Figure's id,
  # or two empty strings in an untagged document. [GraphicUnmark] takes both
  # back at the end.
  method GraphicMark {kind context alt artifact top {bbox {}}} {
    my GraphicCheck $kind $context $alt $artifact
    set decorative [expr {$artifact ne {} && $artifact}]
    if {[my state tagged] ne "1"} {
      return [list {} {}]
    }
    # Inside a form XObject or a tiling pattern the marking is suspended
    # (see [FormBegin]): the stream has no MCIDs of its own, and the
    # invocation carries the mark. No element either - a Figure opened
    # here would hang in the tree with a BBox in the form's coordinates and
    # no content on any page. Measured before 2026-08-18: "image draw -alt"
    # inside [form create] did exactly that, although the manual promises
    # that nothing inside a form is marked.
    if {[my state structureSuspend] eq "1"} {
      return [list {} {}]
    }
    set element {}
    if {$alt ne {}} {
      set options [dict create alt $alt]
      if {$bbox ne {}} {
        dict set options bbox $bbox
      }
      set element [my StructureOpen Figure $options]
      set mark [my StructureMark {} Layout $top]
    } elseif {!$decorative && [my GraphicInFigure]} {
      # Placed inside a Figure the caller opened - [structure Figure -alt
      # ... -script {...}] around a picture and its Caption - the picture
      # IS that figure's content, and the Figure's own -alt describes it:
      # the mark attaches to the open element, as a shape's does. As an
      # artifact it would be decoration inside the very element that says
      # it is not, and PDF/UA refused the document (measured with veraPDF
      # before 2026-08-18: 7.1, an undescribed picture) - with no way to
      # build Figure{picture, Caption} at all.
      set mark [my StructureMark {} Layout $top]
    } else {
      set mark [my StructureMark Artifact]
      if {[llength $mark] && !$decorative} {
        my state undescribedGraphics [linsert [my state undescribedGraphics] \
            end [list kind $kind page [my page current]]]
      }
    }
    my content [my StructureBegin $mark]
    return [list $mark $element]
  }

  # The two refusals of [GraphicMark], on their own so that a caller can
  # have them BEFORE it writes anything the mark does not undo - the image
  # object, the colour space record. GraphicMark calls it first thing as
  # well, so the drawing and the form placement need nothing extra.
  method GraphicCheck {kind context alt artifact} {
    if {$artifact ne {} && ![string is boolean -strict $artifact]} {
      return -code error "tclpdf: $context: -artifact takes a boolean, not\
          \"$artifact\""
    }
    if {$artifact ne {} && $artifact && $alt ne {}} {
      set noun [dict get {image picture svg drawing form placement} $kind]
      return -code error "tclpdf: $context: -artifact and -alt contradict\
          each other - a $noun is either decoration or described, not both"
    }
    return
  }

  # Is the element open right now a Figure? Read from the structure state,
  # not through a structure method: the stack and the element list are
  # what [StructureMark auto] reads too, and the question is small enough
  # not to need a door of its own.
  method GraphicInFigure {} {
    set open [lindex [my state structureStack] end]
    if {$open eq {}} {
      return 0
    }
    return [expr {[dict get [lindex [my state structure] $open] type] eq "Figure"}]
  }

  # The other half: end the mark and close the Figure, when there was one.
  # The Figure is closed even when the mark is empty - inside a form XObject
  # marks are suspended, but an element opened there is still open.
  method GraphicUnmark {mark element} {
    if {[llength $mark]} {
      my content [my StructureEnd $mark]
    }
    if {$element ne {}} {
      my StructureClose $element
    }
    return
  }

  # Which graphics became artifacts because nobody said otherwise, as a list
  # of {kind image|svg|form page N} with N counted from 1. Empty when every
  # one was either described with -alt or declared decoration with
  # -artifact 1 - and always empty in an untagged document, where nothing is
  # marked and nothing is degraded.
  #
  # An artifact is the one way to carry real content past a reader entirely:
  # PDF/UA allows it only for decoration (7.1), and a picture that fell into
  # it by default was never judged either way. The fact is established here,
  # where the marking is written, and judged by ua.tcl - the same division as
  # [linksWithoutContents]. The state key undescribedGraphics is filled by
  # [GraphicMark] for svg.tcl and xObject.tcl as well, since a drawing and a
  # form placement degrade the same way; the query lives here rather than in
  # a module of its own because a picture is the common case, and one place
  # to ask is enough.
  #
  # The fix is one option on the call that placed it, whichever way the
  # caller decides.
  method undescribedGraphics {} {
    return [lmap entry [my state undescribedGraphics] {
      dict replace $entry page [expr {[dict get $entry page] + 1}]
    }]
  }

  # Embed and place in one step, for a picture used exactly once. The alias is
  # derived from the path so that the same file placed twice is still stored
  # once.
  # Embed and place in one call. With -data there is no file name to key the
  # cache on, so the bytes themselves are the key - the same image drawn twice
  # is stored once either way.
  method ImageDraw {args} {
    set path {}
    if {[llength $args] % 2} {
      set path [lindex $args 0]
      set args [lrange $args 1 end]
    }
    lassign [::tclpdf::option partition {data {}} $args] own rest
    set data [dict get $own data]
    if {$path eq {} && $data eq {}} {
      return -code error "tclpdf: image draw needs a file name or -data"
    }
    if {$path ne {}} {
      set alias [my ImageAlias $path]
      set embed [list $path]
    } else {
      set alias "auto:data:[my ImageDigest $data]"
      set embed [list -data $data]
    }
    if {![dict exists [my state images] $alias]} {
      my ImageEmbed $alias {*}$embed
    }
    return [my ImagePlace $alias {*}$rest]
  }

  # A key for a block of bytes. Not a checksum for integrity - just enough for
  # two calls with the same image to find the same entry, with the length in
  # front so that two different images would have to agree on both.
  method ImageDigest {data} {
    set sum 0
    foreach byte [split $data {}] {
      binary scan $byte cu value
      set sum [expr {($sum * 33 + $value) & 0xFFFFFFFF}]
    }
    return "[string length $data]:$sum"
  }

  method ImageInfo {alias} {
    set images [my state images]
    if {![dict exists $images $alias]} {
      return -code error "tclpdf: no image named \"$alias\""
    }
    set image [dict get $images $alias]
    set parsed [dict get $image parsed]
    set result [dict create type [dict get $image type] \
        path [dict get $image path] \
        bytes [string length [dict get $image bytes]] \
        width [dict get $parsed width] height [dict get $parsed height] \
        stencil [dict get $image stencil] mask [dict get $image mask] \
        interpolate [dict get $image interpolate]]
    if {[dict get $image type] eq "png"} {
      dict set result colorType [dict get $parsed colorType]
      dict set result bitDepth [dict get $parsed bitDepth]
      dict set result alpha [::tclpdf::imagePng hasAlpha $parsed]
      # What the FILE gets: an alpha channel is written as an /SMask, exactly
      # as a partial palette is - so it answers softMask here, although the
      # PNG-side classification below it is about tRNS chunks and calls a
      # channel "none". Measured 2026-08-17: a caller reading "transparency
      # none" for a picture that plainly has soft edges was misled.
      # A stencil answers "stencil" and neither of the other three: its bits
      # ARE the transparency, so no /Mask array and no /SMask is written for
      # it - the tRNS chunk it may carry reaches the file as nothing at all
      # (Table 87: with ImageMask true the Mask entry shall not be present).
      dict set result transparency [expr {[dict get $image stencil] ? "stencil"
          : ([::tclpdf::imagePng hasAlpha $parsed]
              ? "softMask" : [::tclpdf::imagePng transparency $parsed])}]
    } else {
      dict set result components [dict get $parsed components]
      dict set result bitDepth [dict get $parsed bitsPerComponent]
      dict set result alpha 0
    }
    if {[dict get $image type] eq "tiff"} {
      # The two facts that are TIFF's alone and that decide how the picture
      # reaches the file: which compression its strips are in, and how many
      # strips there are. Both are read off the tags, so they answer before
      # the picture has been placed - which is when a caller wants them, one
      # placement being the thing that can refuse an over-striped file.
      dict set result compression [dict get $parsed compressionName]
      dict set result strips [dict get $parsed stripCount]
      dict set result rowsPerStrip [dict get $parsed rowsPerStrip]
    }
    # WHAT THE SAMPLES ARE IN, for all three formats alike - the name a
    # resource dictionary would carry for them: DeviceGray, DeviceRGB,
    # DeviceCMYK, or Indexed for a palette. A TIFF has answered this since it
    # was taken in; a JPEG and a PNG had to be worked out from components or
    # colour type by a caller who wanted to lay out around the picture, and
    # working it out is exactly what this package does when it writes the
    # file. One answer, one place.
    #
    # It says what the SAMPLES are, not what the ColorSpace entry of the
    # stream ends up being: with a profile in the file (icc above zero) the
    # picture reaches the page as /ICCBased over this space, and for a
    # palette as /Indexed over it. A stencil has no colour space at all -
    # Table 87 says ColorSpace "shall not be specified" where ImageMask is
    # true, what it paints is the fill colour in force - so it answers empty,
    # which is the same "nobody said" that an absent resolution answers with.
    dict set result space [my ImageSpaceName $image]
    # The size of the ICC profile that will travel with the picture, 0 when
    # the file carries none or -icc 0 left it behind - so a caller can see
    # which of the two a placement will get.
    dict set result icc [string length [dict get $parsed icc]]
    # What the file says about how large its pixels are:
    #
    #   xResolution    dots per inch, or EMPTY when the file gives no
    #   yResolution    absolute measure - which is not the same as 72
    #   resolution     pHYs, JFIF, Exif or none: who said it
    #   pixelAspect    the width of one pixel over its height, 1.0 unless
    #                  the file says otherwise
    #
    # An empty xResolution beside "resolution none" is a file that says
    # nothing, and a placement then assumes 72 dpi. An empty xResolution
    # beside a named source is a file that gave a ratio between the axes
    # and no measure (PNG pHYs unit 0, JFIF units 0, Exif unit 1) - the
    # ratio is in pixelAspect and is used, the 72 is still assumed. Two
    # cases, two answers, and neither of them writes 72 into a field the
    # file never filled.
    set resolution [my ImageResolution $image]
    dict set result xResolution [dict get $resolution x]
    dict set result yResolution [dict get $resolution y]
    dict set result resolution [dict get $resolution source]
    dict set result pixelAspect [dict get $resolution aspect]
    return $result
  }

  # What the file says about its own resolution - the two formats answer in
  # the same shape, and this is the one place that knows which of them is
  # being asked. {source x y aspect}; see the two [resolution] procs.
  method ImageResolution {image} {
    switch -- [dict get $image type] {
      png {return [::tclpdf::imagePng resolution [dict get $image parsed]]}
      tiff {return [my TiffResolution [dict get $image parsed]]}
    }
    return [::tclpdf::imageJpeg resolution [dict get $image parsed]]
  }

  # What a TIFF says about its own resolution, in the shape the other two
  # formats answer in - {source x y aspect}.
  #
  # imageTiff already did the reading and the arithmetic, including the
  # centimetres of ResolutionUnit 3; what is left here is the one thing the
  # shapes disagree about. imageTiff always hands out a number in xDpi so
  # that arithmetic downstream has one, and says beside it whether to believe
  # it; this shape says "nobody knows" by leaving the field EMPTY, so that
  # [image info] can tell a file that states 72 dpi from one that states
  # nothing. So resolutionKnown decides whether the number is passed on at
  # all.
  #
  # ResolutionUnit 1 is the middle case both shapes have: two numbers that
  # are a ratio between the axes and no measure at all. The ratio survives as
  # the pixel aspect, which is the width of one pixel over its height - a
  # pixel is 1/XResolution wide and 1/YResolution high, so the ratio is the
  # other way up from the resolutions. A unit outside the three TIFF 6.0
  # defines is not that case and gets no ratio either: 1 SAYS "a ratio, no
  # measure", while an 0 or a 42 says nothing at all about what the two
  # numbers count, and "source none" is the honest answer to that.
  method TiffResolution {parsed} {
    if {[dict get $parsed resolutionKnown]} {
      return [dict create source XResolution \
          x [dict get $parsed xDpi] y [dict get $parsed yDpi] \
          aspect [expr {double([dict get $parsed yDpi])
              / [dict get $parsed xDpi]}]]
    }
    if {[dict get $parsed resolutionUnit] == 1
        && [dict get $parsed xResolution] > 0
        && [dict get $parsed yResolution] > 0} {
      return [dict create source XResolution x {} y {} \
          aspect [expr {double([dict get $parsed yResolution])
              / [dict get $parsed xResolution]}]]
    }
    return [dict create source none x {} y {} aspect 1.0]
  }

  # How large a picture would come out, in the document unit, with the same
  # options [place] takes. What a caller needs to lay out around it - and the
  # only way to ask, since the sizing itself is private.
  #
  #   $doc image size logo                  -> natural size, the file's own
  #                                            resolution or 72 dpi
  #   $doc image size logo -width 40        -> {40 <proportional height>}
  #   $doc image size logo -dpi 300         -> the size at 300 dpi
  method ImageSize {alias args} {
    set images [my state images]
    if {![dict exists $images $alias]} {
      return -code error "tclpdf: no image named \"$alias\""
    }
    return [my ImageExtent [dict get $images $alias] [::tclpdf::option parse \
        {size {} width {} height {} scale {} dpi {} fit {} fitMode {}} \
        $args "image size"] "image size"]
  }

  # The size to draw at, in the document unit. Given nothing, a pixel is taken
  # to be 1/dpi of an inch, and the dpi is the file's own where the file
  # states one - a 200 dpi scan comes out 200 dpi large. -dpi overrules it;
  # -dpi auto, which is the default, asks for the file's own again.
  #
  # The sizing options are refused here, before anything reads them, and
  # for [image size] as for [image place] - a size that cannot be placed is
  # not one worth answering: lengths and factors above zero, a dpi above
  # zero, a -size of exactly two numbers (geometry.tcl, checkFit). "what"
  # names the call for the refusal.
  method ImageExtent {image options what} {
    # "auto" and the empty string are the same request - the file's own
    # resolution - and neither is a number [checkFit] could weigh, so the
    # word goes before the check rather than through it.
    if {[dict get $options dpi] eq "auto"} {
      dict set options dpi {}
    }
    ::tclpdf::geometry checkFit $options $what
    # The box and the two anchors, checked in the same breath and before
    # anything is read - [fitCheck] in page.tcl, beside the arithmetic that
    # uses them.
    my fitCheck $options $what
    set parsed [dict get $image parsed]
    set pixelWidth [dict get $parsed width]
    set pixelHeight [dict get $parsed height]
    set unit [my cget -unit]
    lassign [my ImageDpi $image [dict get $options dpi]] xdpi ydpi
    set naturalWidth [::tclpdf::geometry fromPoints \
        [expr {$pixelWidth * 72.0 / $xdpi}] $unit]
    set naturalHeight [::tclpdf::geometry fromPoints \
        [expr {$pixelHeight * 72.0 / $ydpi}] $unit]

    return [my fitExtent $naturalWidth $naturalHeight $options]
  }

  # The two resolutions a natural size is derived from - across and down,
  # because a picture may state a different one for each. -dpi, where it was
  # given, is both of them; otherwise the file's own, and 72 where the file
  # states none.
  #
  # 72 dpi is an ASSUMPTION, and it is only ever made here, at the sizing.
  # Nothing writes it into what the file said: [image info] reports an empty
  # xResolution for a file that gave no measure, so that a caller can tell
  # "the file says 72" from "nobody knows".
  #
  # A file may give a ratio between the axes without giving a measure. The
  # ratio is honoured by putting the 72 on the axis with the LARGER pixels,
  # so that a picture never comes out bigger than the plain assumption would
  # have made it - the other axis then gets more dpi and less paper.
  method ImageDpi {image dpi} {
    if {$dpi ne {}} {
      # Read here, before anything divides by it - a NaN or an Inf is a
      # double for Tcl and would have died in the arithmetic below, in words
      # of Tcl's own and from a method the caller never named.
      ::tclpdf::option number $dpi -dpi "image place"
      return [list $dpi $dpi]
    }
    set resolution [my ImageResolution $image]
    if {[dict get $resolution x] ne {}} {
      return [list [dict get $resolution x] [dict get $resolution y]]
    }
    set aspect [dict get $resolution aspect]
    if {$aspect < 1.0} {
      return [list [expr {72.0 / $aspect}] 72.0]
    } elseif {$aspect > 1.0} {
      return [list 72.0 [expr {72.0 * $aspect}]]
    }
    return {72.0 72.0}
  }

  # Turn the parsed picture into PDF objects and register the resource. Called
  # once per image, on first placement.
  #
  # A striped TIFF is several objects and therefore several resources - one
  # name per part, in the order the parts stand in, so that [ImageStack] can
  # walk them from the top of the picture down. The parts are read back OUT
  # of the state rather than from the local copy: [ImageObject] wrote them
  # there, and a stale copy is how a placement comes to name a resource the
  # document never got.
  method ImageWrite {alias image} {
    set number [my ImageObject $alias $image]
    set images [my state images]
    set image [dict get $images $alias]
    if {[dict exists $image parts]} {
      set parts {}
      foreach part [dict get $image parts] {
        set name Im[my ImageCount]
        my resource XObject $name [[my writer] ref [dict get $part object]]
        dict set part resource $name
        lappend parts $part
      }
      dict set images $alias parts $parts
      # The first part's name stands in the resource field as well, so that
      # everything asking "has this picture been written yet" reads one
      # answer. What a placement paints is the parts, never this name.
      dict set images $alias resource [dict get [lindex $parts 0] resource]
      my state images $images
      return $number
    }
    set resourceName Im[my ImageCount]
    my resource XObject $resourceName [[my writer] ref $number]
    dict set images $alias resource $resourceName
    my state images $images
    return $number
  }

  # The picture's own object, created once and reused - the half of
  # [ImageWrite] that a picture serving as another one's mask needs too. A
  # mask is named by a dictionary entry and never by a page, so it gets an
  # object and NO resource name; giving it one would put an XObject into the
  # page's resources that no content stream mentions.
  #
  # A striped TIFF becomes SEVERAL objects here, one per part, and the
  # number that comes back is the first of them; the whole list, with the
  # rows each part holds, is left in the state under "parts". "asMask" says
  # this object is about to be another picture's /Mask or /SMask, which is
  # the one thing a stack cannot be - [TiffStreams] refuses it there, before
  # any of the parts is written.
  method ImageObject {alias image {asMask 0}} {
    if {[dict get $image object] ne {}} {
      # Written already - but a picture that was PLACED on an earlier page and
      # is only now asked for as a mask has never been through [TiffStreams],
      # so the question has to be put again here. Measured while this was
      # being built: a striped TIFF placed on page 1 and then named with
      # -mask went into the file as the /SMask of its FIRST strip, sixteen
      # rows covering the whole picture, and nothing anywhere said so.
      if {[dict exists $image parts]} {
        my TiffStackCheck $alias $image [dict get $image parsed] $asMask
      }
      return [dict get $image object]
    }
    # THE FIRST QUESTION OF ALL, because it is the only one that can be asked
    # before anything exists. Everything below this line creates objects - an
    # ICC profile stream on the JPEG road, a soft mask stream on the PNG one -
    # and a refusal after that leaves them in the file as waste nothing points
    # at. Asked here it costs a dict lookup; asked where the entry is built
    # it cost 2503 bytes of orphaned alpha channel in an archive document,
    # measured on 2026-08-25 with qpdf --qdf, which drops what is
    # unreachable. The RECORD is not made here - see [ImageInterpolateCheck]
    # for why the two are separate calls, and [streams] below for what can
    # still refuse the picture after this point.
    my ImageInterpolateCheck $image $alias
    set parsed [dict get $image parsed]
    set pairs [list Type /XObject Subtype /Image \
        Width [dict get $parsed width] Height [dict get $parsed height]]
    if {[dict get $image stencil]} {
      # An image mask (8.9.6.2): the bits do not carry colour, they decide
      # where the current fill colour reaches the page. So there is no
      # ColorSpace entry to build, nothing to anchor a profile to, and
      # nothing for [ImagePlace] to hold against a PDF/A output intent -
      # the paint it lets through was recorded when the colour was set.
      set streams [::tclpdf::imagePng stencilStreams $parsed \
          [dict get $image invert]]
      lappend pairs {*}[dict get $streams pairs]
      set data [dict get $streams data]
      set space {}
    } elseif {[dict get $image type] eq "jpeg"} {
      set space [::tclpdf::imageJpeg space [dict get $parsed components]]
      set colourSpace /$space
      if {[dict get $parsed icc] ne {}} {
        set colourSpace [my ImageProfileBase $parsed]
        set space ICCBased
      }
      lappend pairs ColorSpace $colourSpace \
          BitsPerComponent [dict get $parsed bitsPerComponent] \
          Filter /DCTDecode
      if {[::tclpdf::imageJpeg inverted $parsed]} {
        lappend pairs Decode [::tclpdf::pdfObj arr {1 0 1 0 1 0 1 0}]
      }
      set data [dict get $image bytes]
    } elseif {[dict get $image type] eq "tiff"} {
      # -invert BEFORE the streams are built, and not as a second Decode
      # array beside the one the file may already need - see [TiffInvert].
      set parsed [my TiffInvert $parsed [dict get $image invert]]
      # The strips, as the streams of one image or of a stack of them. Like
      # the PNG way this runs before ANYTHING is written - it is the last
      # call that can refuse the picture, and all three refusals of
      # [TiffStreams] hang off what it answers - so the profile object below
      # is built afterwards rather than handed in as a base.
      set tiffParts [my TiffStreams $alias $image $parsed $asMask]
      set space [::tclpdf::imageTiff device $parsed]
      set base /$space
      if {[dict get $parsed icc] ne {}} {
        set base [my ImageProfileBase $parsed]
        set space ICCBased
      }
      # The string goes through the document's own constructor, because every
      # string in an encrypted document is encrypted (7.6.2) - the one place
      # an inline image differs, see [ImageInlineStreams].
      lappend pairs ColorSpace [my TiffSpace $parsed $base \
          [list [self namespace]::my BytesStr]] \
          BitsPerComponent [dict get $parsed bitsPerComponent]
      # Sixteen bits per component is PDF 1.5, whatever format the samples
      # came out of (Reference 1.7, Table 4.39) - and after [streams], which
      # is where a 16-bit little-endian file is either turned round or
      # refused: a refused picture must not pin the version floor.
      if {[dict get $parsed bitsPerComponent] == 16} {
        my RequireVersion 1.5 "a 16-bit TIFF picture"
      }
    } else {
      set space [::tclpdf::imagePng device $parsed]
      # [streams] runs before ANYTHING is written, the picture's ICC profile
      # stream included: it is the last call that can refuse the picture, a
      # damaged alpha channel dies decoding in there. So the profile is not
      # handed in as the colour space base - it is put into the finished
      # pairs afterwards, by [anchor]. Measured 2026-08-20: built first, the
      # base left an orphaned profile stream behind whenever the decoding
      # then failed, and a refused call has to leave nothing. The object
      # numbers are the same either way, since [streams] creates none.
      # The palette of an indexed picture is a string, and a string in an
      # encrypted document has to go through the document's own constructor
      # (7.6.2). [streams] is a namespace proc and has no [my], so the way
      # to build one travels as a command prefix; "[self namespace]::my"
      # is what lets it stay a private method.
      set streams [::tclpdf::imagePng streams $parsed \
          [list [self namespace]::my BytesStr]]
      # What the picture needs of the file (Reference 1.7, Table 4.39): a
      # colour key /Mask is PDF 1.3, a soft mask 1.4, sixteen bits per
      # component 1.5. The FlateDecode filter every PNG carries is checked
      # by the writer. Read off [transparency] and [hasAlpha] - the very
      # deciders [streams] consults - rather than off the built pairs, and
      # AFTER [streams], which is the last call that can refuse the picture
      # (a damaged alpha channel dies decoding there): a refused picture
      # must not pin the version floor. Still before the picture's own
      # objects, so a version refusal leaves mask and image unwritten.
      set way [::tclpdf::imagePng transparency $parsed]
      if {$way eq "colourKey"} {
        my RequireVersion 1.3 "a PNG picture with a transparent colour"
      }
      if {[::tclpdf::imagePng hasAlpha $parsed] || $way eq "softMask"} {
        my RequireVersion 1.4 "a PNG picture with an alpha channel"
      }
      if {[dict get $parsed bitDepth] == 16} {
        my RequireVersion 1.5 "a 16-bit PNG picture"
      }
      # The profile object last of the checks and first of the objects: by
      # here nothing can refuse the picture any more.
      set streamPairs [dict get $streams pairs]
      if {[dict get $parsed icc] ne {}} {
        set streamPairs [::tclpdf::imagePng anchor $streamPairs $parsed \
            [my ImageProfileBase $parsed] [list [self namespace]::my BytesStr]]
        set space ICCBased
      }
      lappend pairs {*}$streamPairs
      set data [dict get $streams data]
      if {[dict exists $streams maskData]} {
        # The soft mask is a greyscale image of its own, the same size, and
        # the picture points at it. Written first so that its number exists
        # by the time the picture dictionary names it.
        set maskPairs [list Type /XObject Subtype /Image \
            Width [dict get $parsed width] Height [dict get $parsed height] \
            {*}[dict get $streams maskPairs]]
        set maskNumber [[my writer] addStream $maskPairs \
            [dict get $streams maskData]]
        lappend pairs SMask [[my writer] ref $maskNumber]
      }
    }
    # -invert outside a stencil, where [stencilStreams] has written the
    # Decode array already: the two numbers that reverse a one-component
    # picture (Table 87 - the array is twice as long as the picture has
    # components, and only a greyscale one gets this far; the check is at
    # the embedding). What it is for is a mask drawn the other way round,
    # where the ink is the part that shows.
    if {![dict get $image stencil] && [dict get $image invert]
        && [dict get $image type] ne "tiff"} {
      lappend pairs Decode [::tclpdf::pdfObj arr {1 0}]
    }
    # The same decision as the inline road takes, from the same place - see
    # [ImageInterpolateEntry].
    lappend pairs {*}[my ImageInterpolateEntry $image $alias]
    # The mask a caller named. Which entry it becomes was decided at the
    # embedding, by what the named picture is: a stencil mask is
    # all-or-nothing and goes into /Mask (8.9.6.3, "the Mask entry in an image
    # dictionary may be an image mask ... which serves as an explicit mask for
    # the primary (base) image"), a greyscale picture is coverage and goes
    # into /SMask (11.6.5.2, soft-mask images). Table 87 dates the first at
    # PDF 1.3 and the second at 1.4.
    #
    # The two pictures need not be the same size - "the base image and the
    # image mask need not have the same resolution ... but since all images
    # shall be defined on the unit square in user space, their boundaries on
    # the page will coincide" (8.9.6.3), and Table 143 says the same of a
    # soft-mask image's Width and Height. So nothing here compares them.
    if {[dict get $image mask] ne {}} {
      set maskAlias [dict get $image mask]
      set maskImage [dict get [my state images] $maskAlias]
      if {[dict get $maskImage stencil]} {
        my RequireVersion 1.3 "a picture masked by a stencil"
        set key Mask
      } else {
        my RequireVersion 1.4 "a picture with a soft mask of its own"
        set key SMask
      }
      lappend pairs $key \
          [[my writer] ref [my ImageObject $maskAlias $maskImage 1]]
    }
    if {[info exists tiffParts]} {
      # One object per part: each carries the rows it holds as its own
      # /Height and its own /Filter, because the parts of a stack share
      # neither a stream nor a compression state. What is kept beside them is
      # what [ImageStack] needs to put the picture back together - where each
      # part begins, counted from the top, and how tall it is.
      set records {}
      foreach part $tiffParts {
        set partPairs $pairs
        dict set partPairs Height [dict get $part rows]
        lappend partPairs {*}[dict get $part pairs]
        lappend records [dict create \
            object [[my writer] addStream $partPairs [dict get $part data]] \
            row [dict get $part row] rows [dict get $part rows]]
      }
      set number [dict get [lindex $records 0] object]
    } else {
      set number [[my writer] addStream $pairs $data]
    }
    set images [my state images]
    dict set images $alias object $number
    # Only a picture that really is several images carries a parts list. A
    # single-part TIFF is written, placed and masked exactly as a PNG is,
    # and nothing downstream has to know which format it came from.
    if {[info exists records] && [llength $records] > 1} {
      dict set images $alias parts $records
    }
    # The space of the samples - DeviceGray, DeviceRGB, DeviceCMYK, or
    # ICCBased for a picture travelling with its profile - kept for
    # [ImagePlace] to record; for an Indexed picture it is the base. The
    # PDF/A intent check judges the device names and leaves ICCBased alone,
    # which is the point of carrying the profile.
    dict set images $alias space $space
    my state images $images
    return $number
  }

  # The strips of a TIFF as the streams of PDF images - and the three things
  # this package will not do with a stack of them. Nothing has been written
  # when it answers, so every refusal here leaves the file as it was.
  #
  # A picture in ONE part is a picture like any other and none of the three
  # applies to it: 80 of the 194 measured files are single-stripped, and an
  # uncompressed, a PackBits or an LZW file is one part however many strips
  # it has, because those carry no state and are joined into one stream.
  #
  #   the limit    over [stripLimit] parts the picture is refused rather than
  #                stacked - see the namespace variable for the count
  #   as a mask    Mask and SMask name ONE image XObject (Table 87, Table 143)
  #   with a mask  the mask would cover every part instead of the picture,
  #                since each part is an image of its own on the unit square
  #
  # The way out is the same for all three and is named in each message: a
  # RowsPerStrip that holds the whole picture makes it one image again.
  method TiffStreams {alias image parsed asMask} {
    set streams [::tclpdf::imageTiffStreams streams \
        [dict get $image bytes] $parsed]
    set parts [dict get $streams parts]
    if {[llength $parts] < 2} {
      return $parts
    }
    set count [llength $parts]
    set limit $::tclpdf::image::stripLimit
    if {$count > $limit} {
      return -code error -errorcode {TCLPDF TIFF STRIPS} \
          "tclpdf: [my TiffStackIs $alias $parsed] - tclpdf stacks at most\
          $limit of them, and this picture wants $count; [my TiffStackFix\
          $parsed], or with no compression or PackBits, whose strips carry no\
          state and are joined into a single stream"
    }
    my TiffStackCheck $alias $image $parsed $asMask
    return $parts
  }

  # The two things a stack of images cannot be. Asked from [TiffStreams] when
  # the objects are built, and again from [ImageObject] for a picture whose
  # objects already exist - a picture placed on page 1 and named with -mask on
  # page 2 comes past the second door only.
  method TiffStackCheck {alias image parsed asMask} {
    if {$asMask} {
      return -code error -errorcode {TCLPDF TIFF STACKED} \
          "tclpdf: [my TiffStackIs $alias $parsed], and a mask is ONE image -\
          the Mask and SMask entries of an image dictionary name a single\
          image XObject (ISO 32000-2, Table 87 and Table 143); [my\
          TiffStackFix $parsed], or mask with a PNG"
    }
    if {[dict get $image mask] ne {}} {
      return -code error -errorcode {TCLPDF TIFF STACKED} \
          "tclpdf: [my TiffStackIs $alias $parsed], so it cannot wear -mask\
          \"[dict get $image mask]\" - every part is an image of its own on\
          the unit square (ISO 32000-2, 8.9.6.3), so the mask would be drawn\
          over each of them in turn instead of over the picture; [my\
          TiffStackFix $parsed]"
    }
    return
  }

  # The PDF colour space of a parsed TIFF over a given base: the base itself,
  # or the /Indexed array of a palette image - 8-bit RGB triples in one
  # string with a hival that is the last index (8.6.6.3), which is the shape
  # imageTiff has already turned the file's three 16-bit ramps into.
  #
  # "bytesStr" is the command prefix that makes the lookup string, because
  # the two callers need different ones: an image XObject's string is
  # encrypted with the document, an inline image's is not - the content
  # stream around it already is (7.6.2).
  method TiffSpace {parsed base bytesStr} {
    if {[dict get $parsed space] ne "Indexed"} {
      return $base
    }
    set palette [dict get $parsed palette]
    return "\[/Indexed $base [expr {[string length $palette] / 3 - 1}]\
        [{*}$bytesStr $palette]\]"
  }

  # -invert on a TIFF, decided BEFORE the streams are built, and not as a
  # second Decode array beside the one the file may already need: a
  # WhiteIsZero picture already reverses its samples, and reversing them
  # twice is the picture as it was. So the array is settled once, here, and
  # travels through [streams] with the part it belongs to. Table 87 fixes
  # its length at twice the number of components, and the check at the
  # embedding has already held this picture to one.
  method TiffInvert {parsed invert} {
    if {!$invert} {
      return $parsed
    }
    if {[dict get $parsed decode] eq {}} {
      dict set parsed decode {1 0}
    } else {
      dict set parsed decode {}
    }
    return $parsed
  }

  # What all three refusals begin with, and what all three offer as the way
  # out - written once, because three copies of a sentence are three chances
  # for two of them to say something the third does not.
  method TiffStackIs {alias parsed} {
    return "\"$alias\" is a [dict get $parsed compressionName]-compressed\
        TIFF in [dict get $parsed stripCount] strips, and a compression that\
        begins afresh in every strip becomes one image XObject per strip"
  }

  method TiffStackFix {parsed} {
    return "re-save it with RowsPerStrip [dict get $parsed height], which puts\
        the whole picture in one strip"
  }

  # The ICCBased colour space of a picture's embedded profile, as the PDF
  # text standing where the device space name would - "[/ICCBased n 0 R]"
  # plain, or as the base of an /Indexed array. Through the document-wide
  # profile registry, so five pictures tagged with the same sRGB profile
  # share one stream - and so does the PDF/A output intent, when it names
  # the same profile. ICCBased is PDF 1.3 (Reference 1.7, 4.5.4).
  method ImageProfileBase {parsed} {
    my RequireVersion 1.3 "a picture with an ICC profile"
    return [::tclpdf::pdfObj arr [list /ICCBased [[my writer] ref \
        [my IccProfileObject [dict get $parsed icc] \
            [dict get $parsed iccComponents]]]]]
  }

  method ImageCount {} {
    set count [my state imageCount]
    if {$count eq {}} {
      set count 0
    }
    incr count
    my state imageCount $count
    return $count
  }

  method ImageAlias {path} {
    return "auto:[file normalize $path]"
  }
}

package provide tclpdf::image 1.12