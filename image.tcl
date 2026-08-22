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
}

oo::define ::tclpdf::document::document {

  # $doc image embed <alias> ?path? ?-data bytes? ?-type auto|jpeg|png|tiff?
  # $doc image place <alias> ?-at {x y}? ?-size {w h}? ...
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
      alt {} artifact {}
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
    my GraphicCheck image "image place" [dict get $options alt] \
        [dict get $options artifact]
    set alpha {}
    if {[dict get $options opacity] ne {}} {
      set alpha [my GraphicsOpacity [dict get $options opacity]]
    }
    # Asked of the RESOURCE, not of the object: a picture serving as another
    # one's mask already has an object and no resource name, and reading the
    # object alone left [ImagePlace] naming a resource the page never got.
    if {![dict exists $image resource]} {
      # ImageWrite registers the resource in the state itself, so the local
      # copy has to be refreshed - not doing so is how a place ends up naming
      # a resource that the dictionary already has.
      my ImageWrite $alias $image
      set image [dict get [my state images] $alias]
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
    if {[dict get $image space] ne {}} {
      my ColourSpaceUsed [dict get $image space] "image place"
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
        [dict get $options artifact] $top [my PlacedBox 1 1 $matrix]] \
        mark element
    my save
    if {$alpha ne {}} {
      my content "[::tclpdf::pdfObj name $alpha] gs\n"
    }
    if {[dict exists $image parts]} {
      my ImageStack $image $matrix
    } else {
      my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
      my content "[::tclpdf::pdfObj name [dict get $image resource]] Do\n"
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
      dict set result space [dict get $parsed space]
    }
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
        {size {} width {} height {} scale {} dpi {}} $args "image size"] "image size"]
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
      # -invert on a TIFF is decided BEFORE the streams are built, and it is
      # not a second Decode array beside the one the file may already need:
      # a WhiteIsZero picture already reverses its samples, and reversing
      # them twice is the picture as it was. So the array is settled once,
      # here, and travels through [streams] with the part it belongs to.
      # Table 87 fixes its length at twice the number of components, and the
      # check at the embedding has already held this picture to one.
      if {[dict get $image invert]} {
        if {[dict get $parsed decode] eq {}} {
          dict set parsed decode {1 0}
        } else {
          dict set parsed decode {}
        }
      }
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
      if {[dict get $parsed space] eq "Indexed"} {
        # The lookup of a palette image as PDF reads it: 8-bit RGB triples in
        # one string, and a hival that is the last index (8.6.6.3). imageTiff
        # has already turned the file's three 16-bit ramps into that shape.
        # The string goes through the document's own constructor, because
        # every string in an encrypted document is encrypted (7.6.2).
        set palette [dict get $parsed palette]
        set colourSpace "\[/Indexed $base\
            [expr {[string length $palette] / 3 - 1}] [my BytesStr $palette]\]"
      } else {
        set colourSpace $base
      }
      lappend pairs ColorSpace $colourSpace \
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
    # A hint and nothing more: 8.9.5.3 says Interpolate "is a way for a PDF to
    # declare to a PDF processor that a specific image might render better if
    # interpolation is used", and that "a PDF processor may ignore it". Only
    # written when it is asked for - Table 87 gives it the default false, and
    # a dictionary that repeats a default says nothing.
    if {[dict get $image interpolate]} {
      lappend pairs Interpolate true
    }
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

package provide tclpdf::image 1.10