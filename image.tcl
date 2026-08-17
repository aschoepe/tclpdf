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
    set options [::tclpdf::option parse {type auto data {}} $args "image embed"]
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
    dict set images $alias [dict create type $type parsed $parsed \
        bytes $bytes path $path object {}]
    my state images $images
    return $alias
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
    if {[dict get $image object] eq {}} {
      # ImageWrite registers the resource in the state itself, so the local
      # copy has to be refreshed - not doing so is how a place ends up naming
      # a resource that the dictionary already has.
      my ImageWrite $alias $image
      set image [dict get [my state images] $alias]
    }

    lassign [my ImageExtent $image $options] width height
    lassign [expr {[dict get $options at] eq {} ? {0 0} : [dict get $options at]}] left top
    # The alpha is checked - and its ExtGState made - before the mark and the
    # "q" are out: refused after [save], a bad value left a q without its Q
    # in the stream. Same order as [FormPlace] in xObject.tcl.
    set alpha {}
    if {[dict get $options opacity] ne {}} {
      set alpha [my GraphicsOpacity [dict get $options opacity]]
    }
    # A picture's colour space counts like a painted colour for the PDF/A
    # intent check (ISO 19005-2, 6.2.4.3 - measured with veraPDF, a DeviceRGB
    # picture fails under a CMYK intent, a DeviceCMYK JPEG under sRGB).
    # Recorded per PLACEMENT, not once at ImageWrite: the record names the
    # page, and the object is written on the first page the picture appears
    # on, which may not be the one a caller looks at. And recorded here,
    # after the last value that can be refused, so that a placement that
    # never happened leaves no record. A soft mask is DeviceGray, which
    # every intent admits, and is not recorded.
    my ColourSpaceUsed [dict get $image space] "image place"

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
    # The bounding box goes with the Figure. Not required by the letter of
    # the standard, but the Best Practice Guide names it as what the reading
    # tools rely on to find a figure on the page - and here it costs nothing,
    # because the four values were computed two lines up.
    lassign [my GraphicMark image "image place" [dict get $options alt] \
        [dict get $options artifact] $top [list $left $top $width $height]] \
        mark element
    my save
    if {$alpha ne {}} {
      my content "[::tclpdf::pdfObj name $alpha] gs\n"
    }
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
    if {$artifact ne {} && ![string is boolean -strict $artifact]} {
      return -code error "tclpdf: $context: -artifact takes a boolean, not\
          \"$artifact\""
    }
    set decorative [expr {$artifact ne {} && $artifact}]
    if {$decorative && $alt ne {}} {
      set noun [dict get {image picture svg drawing form placement} $kind]
      return -code error "tclpdf: $context: -artifact and -alt contradict\
          each other - a $noun is either decoration or described, not both"
    }
    if {[my state tagged] ne "1"} {
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
        width [dict get $parsed width] height [dict get $parsed height]]
    if {[dict get $image type] eq "png"} {
      dict set result colorType [dict get $parsed colorType]
      dict set result bitDepth [dict get $parsed bitDepth]
      dict set result alpha [::tclpdf::imagePng hasAlpha $parsed]
      dict set result transparency [::tclpdf::imagePng transparency $parsed]
    } else {
      dict set result components [dict get $parsed components]
      dict set result bitDepth [dict get $parsed bitsPerComponent]
      dict set result alpha 0
    }
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
        {size {} width {} height {} scale {} dpi 72} $args "image size"]]
  }

  # The size to draw at, in the document unit. Given nothing, a pixel is taken
  # to be 1/dpi of an inch - with the default of 72 that is one PDF point,
  # which is the only assumption the format itself makes.
  method ImageExtent {image options} {
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
    set parsed [dict get $image parsed]
    set pairs [list Type /XObject Subtype /Image \
        Width [dict get $parsed width] Height [dict get $parsed height]]
    if {[dict get $image type] eq "jpeg"} {
      set space [::tclpdf::imageJpeg space [dict get $parsed components]]
      lappend pairs ColorSpace /$space \
          BitsPerComponent [dict get $parsed bitsPerComponent] \
          Filter /DCTDecode
      if {[::tclpdf::imageJpeg inverted $parsed]} {
        lappend pairs Decode [::tclpdf::pdfObj arr {1 0 1 0 1 0 1 0}]
      }
      set data [dict get $image bytes]
    } else {
      set space [::tclpdf::imagePng device $parsed]
      set streams [::tclpdf::imagePng streams $parsed]
      # What the picture needs of the file, before its first object goes
      # out (Reference 1.7, Table 4.39): a colour key /Mask is PDF 1.3, a
      # soft mask 1.4, sixteen bits per component 1.5. The FlateDecode
      # filter every PNG carries is checked by the writer.
      if {[dict exists [dict get $streams pairs] Mask]} {
        my RequireVersion 1.3 "a PNG picture with a transparent colour"
      }
      if {[dict exists $streams maskData]} {
        my RequireVersion 1.4 "a PNG picture with an alpha channel"
      }
      if {[dict get $parsed bitDepth] == 16} {
        my RequireVersion 1.5 "a 16-bit PNG picture"
      }
      lappend pairs {*}[dict get $streams pairs]
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
    set number [[my writer] addStream $pairs $data]
    set resourceName Im[my ImageCount]
    my resource XObject $resourceName [[my writer] ref $number]
    set images [my state images]
    dict set images $alias resource $resourceName
    dict set images $alias object $number
    # The device space of the samples - DeviceGray, DeviceRGB, DeviceCMYK -
    # kept for [ImagePlace] to record; the base of an Indexed picture.
    dict set images $alias space $space
    my state images $images
    return $number
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

package provide tclpdf::image 1.3
