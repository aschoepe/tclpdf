#
# tclpdf - PDF generation for Tcl
#
# image - placing JPEG and PNG pictures (8.9.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The public face of the image topic. Reading the two formats happens in
# imageJpeg.tcl, imagePng.tcl and imagePngAlpha.tcl, which nothing outside
# this file loads.
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
# has to be derived, and then through -dpi.
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
# For [IccInspect] and [IccProfileObject]: a picture's embedded profile goes
# through the same reader and the same one-stream-per-profile registry as a
# registered colour space and the PDF/A output intent.
package require tclpdf::color 1.0-
package require tclpdf::graphics 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::image {}

oo::define ::tclpdf::document::document {

  # $doc image embed <alias> ?path? ?-data bytes? ?-type auto|jpeg|png?
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
      default {
        return -code error "tclpdf: unknown image type \"$type\" - known are:\
            auto, jpeg, png"
      }
    }
    # -stencil turns the picture into an image mask (8.9.6.2): what reaches
    # the page is not the picture but the current fill colour, through the
    # bits that are set. Decided HERE, at the embedding, because it decides
    # what the XObject IS - a stencil has no colour space, so it cannot be
    # made one at a placement. [stencilInk] refuses whatever cannot be one
    # bit per sample and reports why; JPEG is refused before it, with its
    # own reason.
    if {[dict get $options stencil]} {
      if {$type ne "png"} {
        return -code error "tclpdf: a stencil mask is one bit per sample (ISO\
            32000-2, Table 87: with ImageMask true BitsPerComponent shall be\
            1), and a DCTDecode filter always delivers 8-bit samples (Table\
            87) - a stencil has to be a 1-bit PNG, not a JPEG"
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
    if {$type eq "jpeg"} {
      return [::tclpdf::imageJpeg space [dict get $parsed components]]
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
    set what [expr {$path ne {} ? "\"$path\"" :
        "the data passed with -data ([string length $bytes] bytes)"}]
    return -code error "tclpdf: $what is neither a JPEG nor a PNG - tclpdf\
        writes those two formats"
  }

  method ImagePlace {alias args} {
    set options [::tclpdf::option parse {
      at {} size {} width {} height {} scale {} rotate 0 opacity {} dpi 72
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
    my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
    my content "[::tclpdf::pdfObj name [dict get $image resource]] Do\n"
    my restore
    my GraphicUnmark $mark $element
    return $alias
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
    # The size of the ICC profile that will travel with the picture, 0 when
    # the file carries none or -icc 0 left it behind - so a caller can see
    # which of the two a placement will get.
    dict set result icc [string length [dict get $parsed icc]]
    return $result
  }

  # How large a picture would come out, in the document unit, with the same
  # options [place] takes. What a caller needs to lay out around it - and the
  # only way to ask, since the sizing itself is private.
  #
  #   $doc image size logo                  -> natural size at 72 dpi
  #   $doc image size logo -width 40        -> {40 <proportional height>}
  #   $doc image size logo -dpi 300         -> the size at 300 dpi
  method ImageSize {alias args} {
    set images [my state images]
    if {![dict exists $images $alias]} {
      return -code error "tclpdf: no image named \"$alias\""
    }
    return [my ImageExtent [dict get $images $alias] [::tclpdf::option parse \
        {size {} width {} height {} scale {} dpi 72} $args "image size"] "image size"]
  }

  # The size to draw at, in the document unit. Given nothing, a pixel is taken
  # to be 1/dpi of an inch - with the default of 72 that is one PDF point,
  # which is the only assumption the format itself makes.
  #
  # The sizing options are refused here, before anything reads them, and
  # for [image size] as for [image place] - a size that cannot be placed is
  # not one worth answering: lengths and factors above zero, a dpi above
  # zero, a -size of exactly two numbers (geometry.tcl, checkFit). "what"
  # names the call for the refusal.
  method ImageExtent {image options what} {
    ::tclpdf::geometry checkFit $options $what
    set parsed [dict get $image parsed]
    set pixelWidth [dict get $parsed width]
    set pixelHeight [dict get $parsed height]
    set unit [my cget -unit]
    set naturalWidth [::tclpdf::geometry fromPoints \
        [expr {$pixelWidth * 72.0 / [dict get $options dpi]}] $unit]
    set naturalHeight [::tclpdf::geometry fromPoints \
        [expr {$pixelHeight * 72.0 / [dict get $options dpi]}] $unit]

    return [my fitExtent $naturalWidth $naturalHeight $options]
  }

  # Turn the parsed picture into PDF objects and register the resource. Called
  # once per image, on first placement.
  method ImageWrite {alias image} {
    set number [my ImageObject $alias $image]
    set resourceName Im[my ImageCount]
    my resource XObject $resourceName [[my writer] ref $number]
    set images [my state images]
    dict set images $alias resource $resourceName
    my state images $images
    return $number
  }

  # The picture's own object, created once and reused - the half of
  # [ImageWrite] that a picture serving as another one's mask needs too. A
  # mask is named by a dictionary entry and never by a page, so it gets an
  # object and NO resource name; giving it one would put an XObject into the
  # page's resources that no content stream mentions.
  method ImageObject {alias image} {
    if {[dict get $image object] ne {}} {
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
    if {![dict get $image stencil] && [dict get $image invert]} {
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
      lappend pairs $key [[my writer] ref [my ImageObject $maskAlias $maskImage]]
    }
    set number [[my writer] addStream $pairs $data]
    set images [my state images]
    dict set images $alias object $number
    # The space of the samples - DeviceGray, DeviceRGB, DeviceCMYK, or
    # ICCBased for a picture travelling with its profile - kept for
    # [ImagePlace] to record; for an Indexed picture it is the base. The
    # PDF/A intent check judges the device names and leaves ICCBased alone,
    # which is the point of carrying the profile.
    dict set images $alias space $space
    my state images $images
    return $number
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

package provide tclpdf::image 1.7