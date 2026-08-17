#
# tclpdf - PDF generation for Tcl
#
# page - pages, the canvas stack, and the coordinate system on them
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Split out of document.tcl, which had grown past 500 lines. Two topics moved
# together on purpose: a coordinate here is only meaningful against a page.
# [coords] mirrors y because tclpdf counts from the top and PDF from the
# bottom, and it needs the page height to do it; [fitExtent] fits into a page.
# A cut between them would put a dependency across a file boundary that today
# is none.
#
# Loaded LAZILY like every topical module, through the core's [unknown]. That
# works even for the private calls the core makes into here - measured under
# 8.6 and 9.0, TclOO's unknown fires for [my Page $index] just as it does for
# [$doc page count]. Only a private method called from OUTSIDE stays out of
# reach, and for that the core has [onSelf].
#
# What lives here:
#
#   page add/count/size/box   the public entry, and the five boxes of 14.11.2
#   PageBox*                  what a box has to satisfy before it is stored:
#                             corners in order (7.9.5), inside the media box
#                             (14.11.2), the page within Annex C's limits
#   content, canvas           the page's content stream, and the stack that
#                             redirects drawing into a form XObject or a tile -
#                             the reason [rect] and [text] work inside a
#                             pattern without knowing about it
#   coords, distance          document unit to points, y from the top
#   extent, fitExtent         sizes, and fitting a natural size into a box
#

package require Tcl 8.6.11-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::pdfObj 1.0-
package require tclpdf::document 1.0-

oo::define ::tclpdf::document::document {

  # -- pages --------------------------------------------------------------

  # $doc page add ?-format a4? ?-orientation landscape? ?-rotate 90?
  # $doc page count
  # $doc page size ?index?        -> {width height} in the document unit
  # $doc page box <name> ?value?  -> media, crop, bleed, trim or art
  # $doc page typeArea ?index?    -> {x0 y0 x1 y1}, the type area on that page
  method page {subcommand args} {
    switch -- $subcommand {
      add {return [my PageAdd {*}$args]}
      count {return [llength $tclpdfPages]}
      current {return $tclpdfCurrent}
      size {return [my PageSize {*}$args]}
      box {return [my PageBox {*}$args]}
      typeArea {return [my PageTypeArea {*}$args]}
      content {
        # The raw content stream of a page, before it is compressed and turned
        # into an object. For diagnostics and for tests - "why is this shape
        # not showing" is answered by looking at the operators, and until the
        # file is written there is nothing else to look at.
        return [dict get [my Page [lindex $args 0]] content]
      }
      default {
        return -code error "tclpdf: unknown page subcommand \"$subcommand\" -\
            known are: add, count, current, size, box, typeArea, content"
      }
    }
  }

  method PageAdd {args} {
    set format [dict get $tclpdfOption format]
    set orientation [dict get $tclpdfOption orientation]
    # Whether the caller SAID which way round, or is getting the default. It
    # matters for a size given as two numbers: those are taken as they stand
    # unless an orientation was asked for.
    set stated 0
    set rotate 0
    foreach {option value} $args {
      switch -- [string trimleft $option -] {
        format {set format $value}
        orientation {
          set orientation $value
          set stated 1
        }
        rotate {set rotate $value}
        default {
          return -code error "tclpdf: unknown option \"$option\" for page add"
        }
      }
    }
    if {$rotate % 90} {
      # 7.7.3.3: only multiples of 90 are permitted, and a reader is free to
      # ignore anything else rather than to complain.
      return -code error "tclpdf: page rotation must be a multiple of 90, got $rotate"
    }
    if {[llength $format] == 2 && !$stated} {
      set orientation {}
    }
    lassign [::tclpdf::geometry pageSize $format $orientation \
        [dict get $tclpdfOption unit]] width height
    # The same limits as for [page box media]: -format {0 0} and negative pairs
    # went through here unchallenged (measured 2026-08-16), and a page of no
    # size is only found by whoever opens the file.
    my PageBoxLimits [list 0 0 $width $height] "-format \"$format\""
    dict set page number [$tclpdfWriter reserve]
    dict set page boxes [dict create media [list 0 0 $width $height]]
    dict set page content {}
    dict set page rotate $rotate
    lappend tclpdfPages $page
    set tclpdfCurrent [expr {[llength $tclpdfPages] - 1}]
    my emit pageAdded $tclpdfCurrent
    return $tclpdfCurrent
  }

  # A box is {x0 y0 x1 y1}, so the size is the DIFFERENCE, not the upper pair.
  # A MediaBox is allowed to start anywhere (7.7.6.3), and taking x1 and y1 as
  # the size answered 220 by 307 for a box of {10 10 220 307} - a page that is
  # in fact 210 by 297.
  method PageSize {{index {}}} {
    set page [my Page $index]
    lassign [dict get $page boxes media] x0 y0 x1 y1
    set unit [dict get $tclpdfOption unit]
    return [list [::tclpdf::geometry fromPoints [expr {$x1 - $x0}] $unit] \
        [::tclpdf::geometry fromPoints [expr {$y1 - $y0}] $unit]]
  }

  # The type area of a page: where flowing text and breaking tables begin
  # and end. Answered as corners {x0 y0 x1 y1} in the document unit, like a
  # page box, so that a caller can place a running head above y0 and start
  # a column at {x0 y0}. Nothing in the file records it - it is a rule for
  # the layout, not a property of the page.
  #
  # -typeArea gives the margins {top bottom ?left right?}; without it the
  # margins are five percent of the page height, top and bottom, and five
  # percent of the page width at the sides - the same rule [table] has
  # always applied to -top and -bottom, now in one place. Two margins that
  # meet leave no area, and that is refused here, at the page they meet on,
  # rather than being handed on as an empty band nothing fits into.
  method PageTypeArea {{index {}}} {
    lassign [my PageSize $index] width height
    set margins [dict get $tclpdfOption typeArea]
    if {$margins eq {}} {
      set margins [list [expr {$height * 0.05}] [expr {$height * 0.05}] \
          [expr {$width * 0.05}] [expr {$width * 0.05}]]
    } elseif {[llength $margins] == 2} {
      lappend margins [expr {$width * 0.05}] [expr {$width * 0.05}]
    }
    lassign $margins top bottom left right
    if {$top + $bottom >= $height || $left + $right >= $width} {
      return -code error "tclpdf: the type area leaves no room on a page of\
          [format %g $width] by [format %g $height] - margins are\
          {[format %g $top] [format %g $bottom] [format %g $left]\
          [format %g $right]}"
    }
    return [list $left $top [expr {$width - $right}] [expr {$height - $bottom}]]
  }

  # Media, crop, bleed, trim and art (7.7.6.3). Values are given in the
  # document unit as {x0 y0 x1 y1} and stored in points.
  method PageBox {name {value {}} {index {}}} {
    set known {media crop bleed trim art}
    if {$name ni $known} {
      return -code error "tclpdf: unknown page box \"$name\" - known are:\
          [join $known {, }]"
    }
    set position [my PageIndex $index]
    set page [lindex $tclpdfPages $position]
    if {$value eq {}} {
      if {![dict exists [dict get $page boxes] $name]} {
        return {}
      }
      set unit [dict get $tclpdfOption unit]
      return [lmap number [dict get [dict get $page boxes] $name] {
        ::tclpdf::geometry fromPoints $number $unit
      }]
    }
    if {[llength $value] != 4} {
      return -code error "tclpdf: a page box is {x0 y0 x1 y1}, got \"$value\""
    }
    set unit [dict get $tclpdfOption unit]
    set box [lmap number $value {
      ::tclpdf::geometry toPoints $number $unit
    }]
    # Everything that can be refused is refused BEFORE the page is touched:
    # a box that fails halfway must not leave the page with a media box it
    # cannot hold.
    my PageBoxCorners $box "page box $name"
    # Bleed, trim and art boxes are PDF 1.3 (Table 30); media and crop have
    # been there since 1.0.
    if {$name in {bleed trim art}} {
      my RequireVersion 1.3 "page box $name"
    }
    set boxes [dict get $page boxes]
    if {$name eq "media"} {
      my PageBoxLimits $box "page box media"
      # A media box set AFTER the others has to hold them still. Shrinking it
      # under a crop box would leave a document that 14.11.2 tells the reader
      # to repair by intersection - the reader correcting what the writer
      # should not have written - and dropping the crop box instead would be
      # a change nobody asked for. So the shrink is refused and the message
      # names the box: set the media box first, or move the box that sticks
      # out.
      dict for {other rect} $boxes {
        if {$other ne "media"} {
          my PageBoxInside $other $rect $box
        }
      }
    } else {
      my PageBoxInside $name $box [dict get $boxes media]
    }
    dict set page boxes $name $box
    lset tclpdfPages $position $page
    return $value
  }

  # -- what a box has to satisfy ---------------------------------------------
  #
  # All three checks take POINTS and report in the document unit; refusing is
  # the rule throughout (compare ShapeRadius): tclpdf writes the file, and a
  # value the reader has to mend is a mistake nobody was told about.

  # 7.9.5 lets a rectangle name any two diagonal corners and asks the READER
  # to normalise. tclpdf does not: the manual promises {x0 y0 x1 y1}, and
  # [coords] and [page size] take that order literally - a reversed media box
  # mirrors y against the wrong edge and reports a negative size. A reversed
  # pair is far more often a corner-and-size confusion than intent, so it is
  # named rather than swapped. The same test catches an EMPTY box: a rectangle
  # of no width or no height shows nothing, and Annex C sets the minimum at
  # 3 units anyway.
  method PageBoxCorners {box what} {
    lassign $box x0 y0 x1 y1
    if {$x1 <= $x0 || $y1 <= $y0} {
      return -code error "tclpdf: $what: x1 must exceed x0 and y1 must exceed\
          y0 in {x0 y0 x1 y1}, got [my PageBoxText $box]"
    }
    return
  }

  # Annex C.2 of ISO 32000-1: a page is at least 3 by 3 and at most 14400 by
  # 14400 units in default user space. Nothing between the writer and the
  # reader checks this - qpdf and veraPDF (PDF/A-1b, measured 2026-08-16) both
  # pass a page of 20000 pt and one of no size at all.
  method PageBoxLimits {box what} {
    lassign $box x0 y0 x1 y1
    set width [expr {$x1 - $x0}]
    set height [expr {$y1 - $y0}]
    # 0.001 pt of slack: 5080 mm IS 14400 pt, and the product of the mm
    # factor may miss it in the last binary digit.
    if {$width < 3 - 0.001 || $height < 3 - 0.001 \
        || $width > 14400 + 0.001 || $height > 14400 + 0.001} {
      return -code error "tclpdf: $what: a page is between 3 and 14400 pt on\
          each side (ISO 32000-1 Annex C), got\
          [my PageBoxText [list $width $height]]"
    }
    return
  }

  # 14.11.2: crop, bleed, trim and art "shall not ordinarily extend beyond the
  # boundaries of the media box"; if they do, the reader cuts them back to the
  # intersection. Refused here for the same reason as above - the caller
  # asked for a box, and would get a different one without a word.
  method PageBoxInside {name box media} {
    lassign $box x0 y0 x1 y1
    lassign $media mx0 my0 mx1 my1
    # 0.001 pt of tolerance for a box computed in mm against a media box that
    # came from the format table: both go through the same product, but a
    # caller's own arithmetic (297 - 10, say) may not.
    set slack 0.001
    if {$x0 < $mx0 - $slack || $y0 < $my0 - $slack \
        || $x1 > $mx1 + $slack || $y1 > $my1 + $slack} {
      return -code error "tclpdf: page box $name [my PageBoxText $box] lies\
          outside the media box [my PageBoxText $media] (ISO 32000-1 14.11.2)"
    }
    return
  }

  # Points back into the document unit for a message: three decimals, trailing
  # zeros dropped, so that A4 reads "{210 297} mm" and not "{210.000 297.000}".
  method PageBoxText {values} {
    set unit [dict get $tclpdfOption unit]
    return "{[lmap value $values {
      set text [format %.3f [::tclpdf::geometry fromPoints $value $unit]]
      string trimright [string trimright $text 0] .
    }]} $unit"
  }

  # Append to the content stream. Everything topical - graphics, text, images -
  # ends up here.
  #
  # If a canvas is pushed (a form XObject being built) the content goes there
  # instead of onto the page. That indirection lives in the core rather than in
  # xObject.tcl for one reason: otherwise every drawing method would have to
  # know whether it is currently drawing into a page or into a form, and each
  # one would have to be taught again. This way [rect], [text] and everything
  # added later work inside a form without a line of their own.
  method content {text {index {}}} {
    if {[llength $tclpdfCanvas]} {
      set top [expr {[llength $tclpdfCanvas] - 1}]
      set canvas [lindex $tclpdfCanvas $top]
      dict append canvas content $text
      lset tclpdfCanvas $top $canvas
      return
    }
    set position [my PageIndex $index]
    set page [lindex $tclpdfPages $position]
    dict append page content $text
    lset tclpdfPages $position $page
    return
  }

  # The drawing surface stack. push takes the size in POINTS.
  #
  #   $doc canvas push $width $height    start collecting elsewhere
  #   $doc canvas pop                    -> the collected content
  #   $doc canvas height                 -> the height coords mirrors against
  method canvas {subcommand args} {
    switch -- $subcommand {
      push {
        lassign $args width height
        lappend tclpdfCanvas [dict create width $width height $height content {}]
        return [llength $tclpdfCanvas]
      }
      pop {
        if {![llength $tclpdfCanvas]} {
          return -code error "tclpdf: canvas pop without a matching push"
        }
        set canvas [lindex $tclpdfCanvas end]
        set tclpdfCanvas [lrange $tclpdfCanvas 0 end-1]
        return [dict get $canvas content]
      }
      depth {
        return [llength $tclpdfCanvas]
      }
      height {
        if {![llength $tclpdfCanvas]} {
          return {}
        }
        return [dict get [lindex $tclpdfCanvas end] height]
      }
      default {
        return -code error "tclpdf: unknown canvas subcommand \"$subcommand\" -\
            known are: push, pop, depth, height"
      }
    }
  }

  method PageIndex {index} {
    if {$index eq {}} {
      set index $tclpdfCurrent
    }
    if {$index < 0 || $index >= [llength $tclpdfPages]} {
      return -code error "tclpdf: no such page: $index - the document has\
          [llength $tclpdfPages] page(s), add one with \"page add\""
    }
    return $index
  }

  method Page {index} {
    return [lindex $tclpdfPages [my PageIndex $index]]
  }

  # -- coordinates --------------------------------------------------------

  # Turn a caller's point into PDF points.
  #
  # Two conversions happen here and nowhere else. First the unit: callers work
  # in millimetres by default, PDF in points. Second the origin: PDF puts it in
  # the BOTTOM left corner with y growing upwards, while anyone laying out an
  # invoice counts from the top. So y is mirrored against the page height.
  #
  # Doing this per call site is how a document ends up with half its content
  # upside down, which is why every topical module goes through here.
  method coords {x y {index {}}} {
    # Inside a form the mirror axis is the FORM's height, not the page's -
    # otherwise everything drawn into a form lands off its bounding box, and
    # the form comes out empty with nothing to explain why.
    set height [my canvas height]
    set left 0
    if {$height eq {}} {
      set page [my Page $index]
      # The origin of the caller's system is the TOP LEFT CORNER OF THE BOX,
      # which is {x0 y1} - not {0 y1}. A MediaBox may start away from zero, and
      # ignoring x0 put everything that far outside the box: still in the file,
      # not on the page, and no validator says a word about it.
      lassign [dict get $page boxes media] left -> -> height
    }
    set unit [dict get $tclpdfOption unit]
    return [list [expr {$left + [::tclpdf::geometry toPoints $x $unit]}] \
        [expr {$height - [::tclpdf::geometry toPoints $y $unit]}]]
  }

  # A length in points - a width or a radius, which has no origin to mirror.
  # The unit defaults to the document's; passing one is for the modules that
  # let a caller override it per call.
  method distance {value {unit {}}} {
    if {$unit eq {}} {
      set unit [dict get $tclpdfOption unit]
    }
    return [::tclpdf::geometry toPoints $value $unit]
  }

  # Several lengths at once - a {width height} pair, in points. Forms and
  # tiling patterns both take a size with an optional -unit, and doing it
  # twice is how the two would drift apart.
  method extent {size {unit {}}} {
    return [lmap value $size {my distance $value $unit}]
  }

  # How large something with a natural size should come out, given -size,
  # -width, -height or -scale. All in the document unit.
  #
  # Shared by pictures and SVG drawings, which is the point: a caller should
  # not have to remember that one of them keeps the aspect ratio when only a
  # width is given and the other does not. Extracted when the second consumer
  # appeared - the copy in the image module was already three branches deep.
  method fitExtent {naturalWidth naturalHeight options} {
    if {[dict get $options size] ne {}} {
      return [dict get $options size]
    }
    set width [dict get $options width]
    set height [dict get $options height]
    if {$width ne {} && $height ne {}} {
      return [list $width $height]
    }
    if {$width ne {}} {
      return [list $width [expr {$width * $naturalHeight / double($naturalWidth)}]]
    }
    if {$height ne {}} {
      return [list [expr {$height * $naturalWidth / double($naturalHeight)}] $height]
    }
    if {[dict exists $options scale] && [dict get $options scale] ne {}} {
      return [list [expr {$naturalWidth * [dict get $options scale]}] \
          [expr {$naturalHeight * [dict get $options scale]}]]
    }
    return [list $naturalWidth $naturalHeight]
  }
}

package provide tclpdf::page 1.0
