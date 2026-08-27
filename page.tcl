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
#   fitCheck, fitAnchor       -fit {w h} with -fitMode, and the -align and
#                             -valign that say where in that box the thing
#                             sits - one piece of arithmetic, since an anchor
#                             is the same sum against a box of no size
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
      size {return [my PageSize [my PageOptionalIndex size $args]]}
      box {return [my PageBox {*}$args]}
      typeArea {return [my PageTypeArea [my PageOptionalIndex typeArea $args]]}
      content {
        # The raw content stream of a page, before it is compressed and turned
        # into an object. For diagnostics and for tests - "why is this shape
        # not showing" is answered by looking at the operators, and until the
        # file is written there is nothing else to look at.
        return [dict get [my Page [lindex $args 0]] content]
      }
      default {
        return -code error -errorcode [list TCLPDF PAGE SUBCOMMAND $subcommand] \
            "tclpdf: unknown page subcommand \"$subcommand\" -\
            known are: add, count, current, size, box, typeArea, content"
      }
    }
  }

  # The one optional argument [page size] and [page typeArea] take. Checked
  # here rather than left to the method's own arity: "page typeArea 0 1"
  # used to answer 'wrong # args: should be "my PageTypeArea ?index?"',
  # which names a private method and not the public call.
  method PageOptionalIndex {subcommand arguments} {
    if {[llength $arguments] > 1} {
      return -code error -errorcode [list TCLPDF PAGE ARGUMENT $subcommand] \
          "tclpdf: page $subcommand takes one optional page\
          index, got \"$arguments\""
    }
    return [lindex $arguments 0]
  }

  method PageAdd {args} {
    # NOT WHILE A FORM OR A TILE IS BEING BUILT. A canvas is a content stream
    # of its own and the script that fills it is not on any page; a "page
    # add" inside it was accepted until 2026-08-27 and did something nobody
    # can have meant - measured: the document had two pages, the current one
    # was the new and empty one, and everything after the call went on
    # drawing into the form, so the caller who thought the break had taken
    # effect wrote the rest of the drawing into a stream that was already
    # being closed. [layer draw] has refused exactly this since it was built,
    # in these words; the two builders of a canvas did not.
    #
    # Before anything is read: a refused page add leaves no page, no state
    # and no half-parsed option.
    if {[my canvas depth]} {
      return -code error -errorcode [list TCLPDF PAGE CANVAS add] \
          "tclpdf: page add inside the -script of a form or a tiling pattern\
          - the script fills a content stream of its own (ISO 32000-1,\
          8.10.1) and is on no page, so the new page would stay empty while\
          the drawing went on into the form; close the script first"
    }
    set format [dict get $tclpdfOption format]
    set orientation [dict get $tclpdfOption orientation]
    # Whether the caller SAID which way round, or is getting the default. It
    # matters for a size given as two numbers: those are taken as they stand
    # unless an orientation was asked for - on this call, or on the document
    # (tclpdf new / configure -orientation, recorded in the state; the
    # default "portrait" is not a request). Measured before 2026-08-17: only
    # the page add's own option counted, and "tclpdf new -format {55 88}
    # -orientation quer" gave 55 by 88 although the manual promised the turn.
    set stated [expr {[my state orientationStated] ne {}}]
    # Through [option parse] like every other call of the package: it counts
    # the pairs, strips the dash and names the options that DO exist. Read by
    # hand here until 2026-08-26, "page add -bogus 1" answered "unknown
    # option" and left the caller to guess the three, and an odd number of
    # words died inside [foreach] in Tcl's own words.
    set parsed [::tclpdf::option parse {format {} orientation {} rotate {}} \
        $args "page add"]
    if {[dict get $parsed format] ne {}} {
      set format [dict get $parsed format]
    }
    if {[dict get $parsed orientation] ne {}} {
      set orientation [dict get $parsed orientation]
      set stated 1
    }
    set rotate [dict get $parsed rotate]
    if {$rotate eq {}} {
      set rotate 0
    }
    # Asked BEFORE the modulo, which is where an empty string or a word used
    # to die as "can't use empty string as operand of %" - a raw Tcl error
    # where this package promises a message of its own.
    if {![string is integer -strict $rotate]} {
      return -code error -errorcode [list TCLPDF PAGE ROTATE number] \
          "tclpdf: page rotation is a whole number of degrees,\
          a multiple of 90, not \"$rotate\""
    }
    if {$rotate % 90} {
      # 7.7.3.3: only multiples of 90 are permitted, and a reader is free to
      # ignore anything else rather than to complain.
      return -code error -errorcode [list TCLPDF PAGE ROTATE multiple] \
          "tclpdf: page rotation must be a multiple of 90, got $rotate"
    }
    # Table 30 gives /Rotate four values, and -90 and 450 are not among them
    # even though both are multiples of 90: poppler works out what they mean
    # and turns the page, a weaker reader is entitled to take the entry as it
    # stands. Normalised rather than refused, because -90 and 450 say
    # perfectly clearly what the caller wants and there is exactly one entry
    # that says it. Tcl's % follows the sign of the DIVISOR, so one
    # expression covers both directions: -90 % 360 is 270.
    set rotate [expr {$rotate % 360}]
    if {[llength $format] == 2 && !$stated} {
      set orientation {}
    }
    # A size given as two numbers goes into [pageSize] and from there into
    # [toPoints], which takes NaN for a double. The limits below are
    # comparisons and NaN is false against all of them, so a page of NaN by
    # NaN was accepted and every coordinate on it came out NaN - measured on
    # 2026-08-25. Refused here, where the numbers are still the caller's.
    if {[llength $format] == 2} {
      foreach number $format {
        # A word among the two is [pageSize]'s own refusal, as before - see
        # [distance].
        if {[string is double -strict $number]} {
          ::tclpdf::option number $number "-format" "page add"
        }
      }
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
      return -code error -errorcode [list TCLPDF PAGE TYPEAREA room] \
          "tclpdf: the type area leaves no room on a page of\
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
      return -code error -errorcode [list TCLPDF PAGE BOX $name] \
          "tclpdf: unknown page box \"$name\" - known are:\
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
      return -code error -errorcode [list TCLPDF PAGE BOX shape] \
          "tclpdf: a page box is {x0 y0 x1 y1}, got \"$value\""
    }
    set box [my extent $value]
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
      return -code error -errorcode [list TCLPDF PAGE BOX $what] \
          "tclpdf: $what: x1 must exceed x0 and y1 must exceed\
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
      return -code error -errorcode [list TCLPDF PAGE BOX $what] \
          "tclpdf: $what: a page is between 3 and 14400 pt on\
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
      return -code error -errorcode [list TCLPDF PAGE BOX $name] \
          "tclpdf: page box $name [my PageBoxText $box] lies\
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

  # A value that belongs to the CURRENT content stream rather than to the
  # document: the top canvas while a form or a pattern is being built, the
  # current page otherwise. Graphics state that this package has to remember
  # lives here - the colours [style] set, for one - because a stream starts
  # fresh and knows nothing of the page before it or the page it is placed
  # on. Answers {} for a key never set.
  #
  #   my streamState key          -> value
  #   my streamState key value    sets it
  method streamState {key args} {
    if {[llength $tclpdfCanvas]} {
      set top [expr {[llength $tclpdfCanvas] - 1}]
      set record [lindex $tclpdfCanvas $top]
    } else {
      set top [my PageIndex {}]
      set record [lindex $tclpdfPages $top]
    }
    if {![llength $args]} {
      return [expr {[dict exists $record $key] ? [dict get $record $key] : {}}]
    }
    dict set record $key [lindex $args 0]
    if {[llength $tclpdfCanvas]} {
      lset tclpdfCanvas $top $record
    } else {
      lset tclpdfPages $top $record
    }
    return [lindex $args 0]
  }

  # The drawing surface stack. push takes the size in POINTS.
  #
  #   $doc canvas push $width $height    start collecting elsewhere
  #   $doc canvas pop                    -> the collected content
  #   $doc canvas height                 -> the height coords mirrors against
  #   $doc canvas id                     -> WHICH stream is being written
  method canvas {subcommand args} {
    switch -- $subcommand {
      push {
        lassign $args width height
        # A serial per push, never reused in the life of the document. It is
        # what [canvas id] hands out, and the reason it is a counter rather
        # than the position in the stack: two sibling forms sit at the same
        # depth and are two different streams, which is exactly the
        # distinction a pattern anchor has to make (pattern.tcl).
        set serial [my state canvasSerial]
        if {$serial eq {}} {
          set serial 0
        }
        incr serial
        my state canvasSerial $serial
        lappend tclpdfCanvas [dict create width $width height $height \
            content {} serial $serial]
        return [llength $tclpdfCanvas]
      }
      pop {
        if {![llength $tclpdfCanvas]} {
          return -code error -errorcode [list TCLPDF PAGE CANVAS pop] \
              "tclpdf: canvas pop without a matching push"
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
      id {
        # WHICH content stream is being written, as a two-word identity:
        # {stream <serial>} for a form XObject or a tile, {page <index>} for
        # a page, and empty for a document that has neither yet.
        #
        # The DEPTH is not that identity, and taking it for one is what let a
        # gradient measured in form A be used in form B (both at depth 1) and
        # one measured on page 1 be used on a page of another size (both at
        # depth 0) - pattern space belongs to the stream, not to a level of
        # nesting (ISO 32000-2, 8.7.2).
        if {[llength $tclpdfCanvas]} {
          return [list stream [dict get [lindex $tclpdfCanvas end] serial]]
        }
        if {![llength $tclpdfPages]} {
          return {}
        }
        return [list page $tclpdfCurrent]
      }
      default {
        return -code error -errorcode [list TCLPDF PAGE CANVAS $subcommand] \
            "tclpdf: unknown canvas subcommand \"$subcommand\" -\
            known are: push, pop, depth, height, id"
      }
    }
  }

  method PageIndex {index} {
    if {$index eq {}} {
      set index $tclpdfCurrent
    }
    if {$index < 0 || $index >= [llength $tclpdfPages]} {
      return -code error -errorcode [list TCLPDF PAGE INDEX $index] \
          "tclpdf: no such page: $index - the document has\
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
  # The rectangle a placement covers, in the caller's system: the upright box
  # around the four corners of a width x height area put through the matrix
  # that goes into the stream. Both callers of it - [FormPlace] in xObject.tcl
  # with the form's own size, [ImagePlace] in image.tcl with the unit square,
  # since an image XObject IS the unit square - need the same answer, and a
  # second copy of the arithmetic is how the two would drift apart.
  #
  # Why the corners rather than the rectangle asked for: ISO 32000-2,
  # 14.8.5.4.3 asks a /BBox for "the rectangle that completely encloses" the
  # visible content. Under a rotation the rectangle asked for does neither -
  # it leaves part of the content outside and claims page the content never
  # covers - and nothing downstream can tell that the numbers are wrong.
  # The turned hull has no error term: for a rotated rectangle the upright box
  # around its four corners encloses it exactly.
  #
  # The way back into the caller's system runs through [coords] rather than
  # around it: [my coords 0 0] IS the caller's origin in PDF points, media box
  # offset and page height included, and inside a form it is the form's own
  # origin. Subtracting it and converting back is the inverse of the one
  # conversion this package has.
  # A CLIP narrows it. A placement that covers a box has been cut back to that
  # box (image place -fitMode cover), so the rectangle that "completely
  # encloses the visible content" is what is left of the placement inside the
  # clip - the placement itself would claim page on the sides the clip took
  # away. Both rectangles are upright and in the caller's system, so the
  # intersection is exact; an empty one comes back as a box of no size at the
  # clip's corner, which is what a placement entirely outside its box covers.
  # AND THROUGH THE TRANSFORMATION IN FORCE. 14.8.5.4.3 asks for the
  # rectangle in DEFAULT USER SPACE, and a "cm" that a [transform] put in
  # force before the placement stands between the two: the matrix below maps
  # the corners into the space the stream is CURRENTLY in, not into the space
  # the page started in. Measured 2026-08-27: under "transform -translate
  # {50 0}" a form placed at 10 mm sits at 60 mm on the paper and declared
  # "/BBox [28.34646 226.77165 ...]" - the numbers of the untransformed
  # placement, four values that are wrong with nothing in the file to say so,
  # since no validator compares a /BBox with the stream. See [ctm].
  method PlacedBox {width height matrix {clip {}}} {
    set active [my ctm]
    if {$active ne [::tclpdf::geometry identity]} {
      set matrix [::tclpdf::geometry multiply $matrix $active]
    }
    lassign [my coords 0 0] zeroX zeroY
    set unit [my cget -unit]
    set xs {}
    set ys {}
    foreach {cornerX cornerY} [list 0 0 $width 0 $width $height 0 $height] {
      lassign [::tclpdf::geometry apply $matrix $cornerX $cornerY] pointX pointY
      lappend xs [::tclpdf::geometry fromPoints [expr {$pointX - $zeroX}] $unit]
      lappend ys [::tclpdf::geometry fromPoints [expr {$zeroY - $pointY}] $unit]
    }
    set left [::tcl::mathfunc::min {*}$xs]
    set top [::tcl::mathfunc::min {*}$ys]
    set right [::tcl::mathfunc::max {*}$xs]
    set bottom [::tcl::mathfunc::max {*}$ys]
    return [my boxClipped [list $left $top [expr {$right - $left}] \
        [expr {$bottom - $top}]] $clip]
  }

  # A box cut back to what a clipping rectangle leaves of it, both as
  # {x y width height} in the document unit.
  #
  # Its own method because THREE roads need it and each of them answers a
  # structure element with the result: a picture, a form and a drawing, all
  # three of which may be placed with -fitMode cover and are then larger
  # than the box the caller named. ISO 32000-2, 14.8.5.4.3 asks the BBox of
  # an element for "the rectangle that completely encloses the VISIBLE
  # content" - and what a clip cut away is not visible. Measured on
  # 2026-08-25: a drawing covered into a 40 mm box reported a BBox reaching
  # to x = -113 pt, over the left edge of the paper and four times as wide
  # as what a reader sees, while the picture road at the same call reported
  # the box itself. That number is also what [svg] and [form place] hand
  # back to the caller, who sets the caption under it.
  method boxClipped {box clip} {
    if {[llength $clip] != 4} {
      return $box
    }
    lassign $box left top width height
    lassign $clip clipLeft clipTop clipWidth clipHeight
    set right [expr {max($left, min($left + $width, $clipLeft + $clipWidth))}]
    set bottom [expr {max($top, min($top + $height, $clipTop + $clipHeight))}]
    set left [expr {min($right, max($left, $clipLeft))}]
    set top [expr {min($bottom, max($top, $clipTop))}]
    return [list $left $top [expr {$right - $left}] [expr {$bottom - $top}]]
  }

  # A placement matrix turned about the point -at names - THE one place the
  # manual's promise "-rotate turns the placement about the point -at names"
  # is arithmetic, for the picture road and the form road alike.
  #
  # Both build their upright placement first and then turn it, and both had
  # the turn wrong in the same way until 2026-08-27 (eighth review, Nr. 70):
  # composed BEFORE the translation, the fixed point is wherever the thing's
  # own (0, 0) lands - the BOTTOM left corner of the upright placement, a
  # height away from the top left corner -at names. Nothing in the file says
  # so; only the caller who drew a mark at -at sees it.
  #
  # Here rather than twice: the shared piece is not the "move, turn, move
  # back" alone - that is [geometry about] - but the wiring around it, the
  # [coords] of -at and the order of the multiplication. dup-scan found the
  # second copy the day it was written.
  #
  # left and top are -at IN THE CALLER'S SYSTEM (the anchored corner: a
  # -align or -valign that moves it is refused beside -rotate, see
  # [fitCheck], so the two are the same point). The matrix goes in and comes
  # out in PDF points, and an angle of zero returns it untouched rather than
  # multiplying by an identity that is only nearly one.
  method turnedAbout {matrix left top degrees} {
    if {$degrees == 0} {
      return $matrix
    }
    lassign [my coords $left $top] pivotX pivotY
    return [::tclpdf::geometry multiply $matrix \
        [::tclpdf::geometry about [::tclpdf::geometry rotate $degrees] \
            $pivotX $pivotY]]
  }

  # -- the transformation in force ----------------------------------------

  # WHERE THE CURRENT STREAM IS, as the matrix that maps its coordinates into
  # the default user space of the page: the product of every "cm" the API has
  # put out and not taken back again.
  #
  # It is kept because three answers depend on it and none of them can be
  # read off the stream. A Figure's /BBox is stated in default user space
  # (ISO 32000-2, 14.8.5.4.3), a link's /Rect likewise, and the box [svg] and
  # [form place] hand back to the caller is what the caption goes under - all
  # three were worked out from the placement alone until 2026-08-27 and were
  # simply wrong under an open [transform]. Nothing in the file contradicts
  # them, which is why it stood for a year.
  #
  # Per STREAM, through [streamState]: a form or a tile is a space of its own
  # and starts at the identity, and the CTM of the page it is later placed on
  # is none of its business (8.10.1 - the Do concatenates, and that happens
  # at the placement, which is where the placement matrix already stands).
  # [transform] concatenates it, [save] puts it away and [restore] brings it
  # back, exactly as they do for the colours - all three in graphics.tcl, the
  # module that writes the "cm". A document that never transformed anything
  # never loads that module, and the empty state answers the identity here.
  #
  # NOT tracked: the "cm" that [image place], [form place], [shading] and
  # [svg] write inside a q/Q of their own. Those are closed before the next
  # call sees them, so they are never in force when anything asks.
  method ctm {} {
    set matrix [my streamState ctm]
    if {[llength $matrix] != 6} {
      return [::tclpdf::geometry identity]
    }
    return $matrix
  }

  # A box in the caller's system - {left top width height}, counted from the
  # top - put through the transformation in force, as the upright hull of its
  # four turned corners. Same in, same out.
  #
  # The road for a box that was NOT worked out from a placement matrix: a
  # drawing computes its own rectangle in document units ([svg]), and putting
  # it through [PlacedBox] would mean inventing a matrix for it. The turned
  # hull is the same answer 14.8.5.4.3 asks of every other road.
  #
  # The identity is answered with the box itself rather than with four
  # numbers that are equal to it up to the unit conversion: mm to points and
  # back is a multiplication and a division, and a box that came out
  # 39.99999999999999 mm wide where nothing was transformed would be a change
  # nobody asked for.
  method ctmBox {box} {
    set matrix [my ctm]
    if {$matrix eq [::tclpdf::geometry identity]} {
      return $box
    }
    lassign $box left top width height
    lassign [my coords 0 0] zeroX zeroY
    set unit [my cget -unit]
    set xs {}
    set ys {}
    foreach {cornerX cornerY} [list $left $top [expr {$left + $width}] $top \
        [expr {$left + $width}] [expr {$top + $height}] \
        $left [expr {$top + $height}]] {
      lassign [my coords $cornerX $cornerY] pointX pointY
      lassign [::tclpdf::geometry apply $matrix $pointX $pointY] pointX pointY
      lappend xs [::tclpdf::geometry fromPoints [expr {$pointX - $zeroX}] $unit]
      lappend ys [::tclpdf::geometry fromPoints [expr {$zeroY - $pointY}] $unit]
    }
    set x [::tcl::mathfunc::min {*}$xs]
    set y [::tcl::mathfunc::min {*}$ys]
    return [list $x $y [expr {[::tcl::mathfunc::max {*}$xs] - $x}] \
        [expr {[::tcl::mathfunc::max {*}$ys] - $y}]]
  }

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
    # Through [my distance] rather than around it, so that the one check a
    # measurement gets is the one every measurement gets - see there.
    return [list [expr {$left + [my distance $x]}] \
        [expr {$height - [my distance $y]}]]
  }

  # A length in points - a width or a radius, which has no origin to mirror.
  # The unit defaults to the document's; passing one is for the modules that
  # let a caller override it per call.
  # THE ONE GATE EVERY MEASUREMENT PASSES, and therefore the place the
  # non-numbers are turned away at. [geometry toPoints] reads its value with
  # [string is double -strict], which is true for "NaN" and for "Inf": NaN then
  # compares false against every range check written as a comparison, travels
  # on through the arithmetic, and surfaces as Tcl's own "can't use
  # non-numeric floating-point value as operand of \"*\"" from inside a method
  # the caller never named - measured on 2026-08-25 for -at, -size, -radius,
  # -scale, -fit, -from/-to and page -format alike, every one of them a raw
  # error against the promise that every refusal begins with "tclpdf:".
  #
  # Here rather than per module, and rather than at [pdfObj num]: this is the
  # single conversion from the caller's unit into points, so a value refused
  # here has not yet reached a matrix, a mark or a "q". [pdfObj num] keeps its
  # own "number has no PDF representation" - that one stands at the moment of
  # WRITING and is the last line of defence behind this one.
  #
  # AND THE RANGE IS ASKED HERE TOO, not only there. A PDF real carries about
  # +/-3.403e38 (Annex C.2); a length past that was taken by every module and
  # refused by [pdfObj num] while the operators of the call were already in
  # the stream - measured 2026-08-26, "rect -at {1e39 20}" left its colour
  # and its "q" behind, and in a tagged document its marked-content bracket.
  # The gate every measurement passes is the place for it: one line here
  # instead of one copy per topic (text.tcl carried such a copy, TextLength).
  # The figure itself stands once, in [pdfObj fits], which [option number]
  # asks.
  method distance {value {unit {}}} {
    if {$unit eq {}} {
      set unit [dict get $tclpdfOption unit]
    }
    # Only a value that IS a double is judged here. A word is not a
    # measurement at all, and [geometry toPoints] has said so in those words
    # since 1.0 - "not a measurement: \"a\"" - which is what the tests of
    # three modules read and what a caller who mistyped a variable name sees.
    # What was missing is the double that is no number, and that is what this
    # line adds.
    if {[string is double -strict $value]} {
      ::tclpdf::option number $value "a length"
    }
    # Asked a second time of the CONVERTED value, because the unit is a
    # factor: 2e38 mm is inside the range as the caller wrote it and 5.7e38
    # points once it is one. The first call is the one that answers in the
    # caller's own figure and catches NaN before the arithmetic; this one
    # catches the band the factor opens up.
    set points [::tclpdf::geometry toPoints $value $unit]
    return [::tclpdf::option number $points "a length in points"]
  }

  # Several lengths at once - a {width height} pair, in points. Forms and
  # tiling patterns both take a size with an optional -unit, and doing it
  # twice is how the two would drift apart.
  method extent {size {unit {}}} {
    return [lmap value $size {my distance $value $unit}]
  }

  # A length that is STILL ABOVE ZERO ONCE THE FILE HAS IT - the refusal that
  # goes with [pdfObj written], so that the wording stands once for all the
  # commands that need it.
  #
  # Four of them wrote the forbidden zero on 2026-08-27 (Nr. 65-68 of the
  # eighth review): a stitching /Bounds against Table 40, a dash array
  # against 8.4.3.6, /XStep against Table 75, a form's and a tile's /BBox
  # against Table 95. Each had a "> 0" of its own, each asked it of the
  # number the CALLER handed in, and each then wrote a real of five decimals
  # (7.3.3) - which 0.000001 is not. The file is what a reader gets, so the
  # file is what the check has to be about; that is the cut [geometry
  # singular] draws for a matrix, in the same words and for the same reason.
  #
  # ONLY THE FILE'S HALF IS ASKED HERE. Whether a length may be negative at
  # all is the calling command's own question - a size may not, a pattern
  # step may - and each of them already words that refusal in its own terms,
  # naming the option and the object. This one adds the half none of them can
  # see from where they stand.
  #
  # VALUE IS THE NUMBER AS IT WILL BE WRITTEN, so a caller converts to points
  # first ([distance], [extent]): a millimetre and a point round differently,
  # and asking in the wrong unit refuses values the file holds perfectly
  # well. "what" names it in the caller's terms ("the width of form \"f\""),
  # errorcode is the whole code of the command doing the refusing - one
  # shared wording, not one shared error class, because a caller catches
  # "form" or "pattern", never "page".
  #
  # In the core rather than in one of the four modules because none of the
  # four loads any of the others, and because the fifth caller will be a
  # sixth module again.
  method aboveZero {value what errorcode} {
    if {[::tclpdf::pdfObj written $value] > 0} {
      return $value
    }
    return -code error -errorcode $errorcode \
        "tclpdf: $what is \"$value\" pt, which is 0 in the file - a PDF real\
        carries five decimals (ISO 32000-1, 7.3.3), so a length below\
        0.00001 pt is written as zero and everything measured by it\
        collapses"
  }

  # How large something with a natural size should come out, given -size,
  # -width, -height or -scale. All in the document unit.
  #
  # Shared by pictures and SVG drawings, which is the point: a caller should
  # not have to remember that one of them keeps the aspect ratio when only a
  # width is given and the other does not. Extracted when the second consumer
  # appeared - the copy in the image module was already three branches deep.
  method fitExtent {naturalWidth naturalHeight options} {
    # NaN AND Inf FIRST, because everything below this is arithmetic. The
    # sizing options are checked by [geometry checkFit] before this runs, and
    # that check is written as "$value <= 0" - false for NaN, which therefore
    # arrives here and dies as an operand of "*" or of "/". Said here rather
    # than in each of the three roads that call this (a picture, a drawing, a
    # form), and with the option's own name, since that is what the caller
    # wrote. -fit is not among them: [fitCheck] answers for the box.
    foreach key {size width height scale} {
      if {![dict exists $options $key] || [dict get $options $key] eq {}} {
        continue
      }
      foreach value [dict get $options $key] {
        # A word is [geometry checkFit]'s refusal, and it made it above.
        if {[string is double -strict $value]} {
          ::tclpdf::option number $value "-$key"
        }
      }
    }
    # -fit names a BOX and keeps the proportions, which is the one sizing
    # option that cannot be worked out from the natural size alone: the box
    # decides the factor, and which of its two edges decides it is what
    # -fitMode says. It stands before -size because it is the same question
    # answered with an aspect ratio kept - a caller who gave both is refused
    # in [fitCheck] long before this runs.
    if {[dict exists $options fit] && [dict get $options fit] ne {}} {
      lassign [dict get $options fit] boxWidth boxHeight
      set across [expr {$boxWidth / double($naturalWidth)}]
      set down [expr {$boxHeight / double($naturalHeight)}]
      # contain takes the SMALLER factor, so both edges fit and the thing is
      # whole; cover takes the larger, so both edges are covered and what
      # sticks out is cut off by the caller of this - see [ImagePlace].
      set factor [expr {[dict get $options fitMode] eq "cover"
          ? max($across, $down) : min($across, $down)}]
      return [list [expr {$naturalWidth * $factor}] \
          [expr {$naturalHeight * $factor}]]
    }
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

  # -- fitting into a box, and where in it the thing sits -------------------
  #
  # THE SAME TWO WORDS THE REST OF THE PACKAGE ALREADY USES. Which point of a
  # thing the given coordinate names is asked twice, once per axis, and both
  # questions have an answer in this package already: [text] says -align
  # left|center|right for the horizontal one (without -width, "left starts
  # there, right ends there, center is centred on it"), and a table cell says
  # valign top|middle|bottom for the vertical one. So a picture says the same,
  # with the same words and the same values.
  #
  # NOT -anchor, although that is what a picture's nine positions are usually
  # called: [text] has an -anchor already and it means baseline or top - one
  # AXIS, not a corner. An -anchor top on a picture would have to mean "top
  # edge, centred across", and the same word would then place a line of text
  # without touching its x and a picture with its x moved. One word, two
  # senses, in one package: a caller could only find that out by trying it.
  # -align/-valign has no such reading, and it buys the nine positions from
  # two options a reader of this manual has already met.
  #
  # -fit {w h} is the box. It and the anchor are ONE piece of arithmetic and
  # not two: the corner is [at] + fraction * (box - drawn) on each axis, and
  # WITHOUT a box that is a box of no size, which puts the same fractions to
  # work as the plain anchor - 0 leaves the corner where it was, 1 pulls the
  # thing fully left of or above it, 0.5 halves it. One formula, so an anchor
  # and an anchor inside a box cannot drift apart.

  # What -fit, -fitMode, -align and -valign have to be before [fitExtent] and
  # [fitAnchor] read them. Refused HERE, at the call, like every other sizing
  # option (geometry.tcl, checkFit) - the two run side by side because they
  # answer for different options, not because either is a copy. "what" names
  # the call for the refusal ("image place").
  method fitCheck {options what} {
    set fit [expr {[dict exists $options fit] ? [dict get $options fit] : {}}]
    if {$fit ne {}} {
      if {[catch {llength $fit} count] || $count != 2} {
        return -code error -errorcode [list TCLPDF FIT BOX $fit $what] \
            "tclpdf: -fit of $what is a box {width height}, not \"$fit\""
      }
      # [option finite] and not [string is double -strict]: the latter is true
      # for NaN, and NaN is false against "<= 0" as it is against every other
      # comparison, so a box of NaN was waved past this and died in the
      # arithmetic below it. text.tcl had to say so a second time in its own
      # words for exactly that reason; with the check here the box is answered
      # once, for every road that fits into one.
      foreach value $fit {
        if {![::tclpdf::option finite $value] || $value <= 0} {
          return -code error -errorcode [list TCLPDF FIT BOX $fit $what] \
              "tclpdf: -fit of $what takes lengths above zero, not\
              \"$value\""
        }
      }
      # A box already says how large the thing comes out, and so does each of
      # these. Given both, one of them would have to win in silence - and
      # whichever won, the other is a sentence the caller wrote and nothing
      # read. -dpi is not among them: it says how large a PIXEL is, which is
      # what the natural proportions are made of, and those are what -fit
      # keeps.
      foreach key {size width height scale} {
        if {[dict exists $options $key] && [dict get $options $key] ne {}} {
          return -code error -errorcode [list TCLPDF FIT SIZE $key $what] \
              "tclpdf: -fit of $what fits into a box and -$key sets the size,\
              so the two contradict each other - fit into the box, or give\
              the size and place it yourself"
        }
      }
    }
    set mode [expr {[dict exists $options fitMode] ?
        [dict get $options fitMode] : {}}]
    if {$mode ne {}} {
      if {$mode ni {contain cover}} {
        return -code error -errorcode [list TCLPDF FIT MODE $mode $what] \
            "tclpdf: -fitMode of $what is contain (the whole of it inside the\
            box) or cover (the whole box covered, what sticks out cut off),\
            not \"$mode\""
      }
      if {$fit eq {}} {
        return -code error -errorcode [list TCLPDF FIT MODE $mode $what] \
            "tclpdf: -fitMode of $what says how to fill a box and no box was\
            given - add -fit {width height}"
      }
    }
    foreach {option key} {-align align -valign valign} {
      if {![dict exists $options $key]} {
        continue
      }
      if {[my FitFraction $key [dict get $options $key]] eq {}} {
        return -code error \
            -errorcode [list TCLPDF FIT ALIGN $option \
                [dict get $options $key] $what] \
            "tclpdf: $option of $what is\
            [expr {$key eq "align" ? "left, center or right" :
                "top, middle or bottom"}] - not\
            \"[dict get $options $key]\""
      }
    }
    # A TURNED THING IS PLACED BY ITS CORNER, and these three describe an
    # UPRIGHT box - so the two say different things about where the thing
    # ends up, and neither of them is wrong on its own. Measured before this
    # refusal stood: a picture fitted into a 40 by 40 box at {20 20} and
    # turned by 90 degrees came out entirely beside that box, because the
    # turn happens about the corner the fitting had just moved; and a covered
    # box was cut by a rectangle standing at an angle to the picture, so
    # neither promise held - the box was not covered in its corners and the
    # picture was cut where nobody asked.
    #
    # Refused rather than defined one way or the other. Turning the clip with
    # the picture would need a path of four corners and would still leave the
    # box's own corners bare; leaving it upright cuts a picture nobody aimed
    # there. The way out is one call: [image size] takes -fit and answers the
    # fitted size, and -size with -rotate turns that about -at as it always
    # has.
    #
    # -align left and -valign top are NOT given up by this: they are what a
    # placement does anyway, so a caller who spells them out beside -rotate
    # gets exactly what the words say. Only a value that MOVES the corner is
    # refused, which is why the fractions are compared rather than the words.
    # An angle first, and a real one. NaN is a double to Tcl and is unequal to
    # 0 - as it is to everything, itself included - so a NaN -rotate walked
    # into the refusal below and was reported as a combination of options
    # instead of as the value it is; without -fit it walked past it and into
    # cos() and sin(). All three roads that turn a placement come through
    # here, so the angle is answered once. Only a value that IS a double is
    # judged here: a -rotate of "x" is not an angle at all, and each road says
    # so in its own words already.
    if {[dict exists $options rotate]
        && [string is double -strict [dict get $options rotate]]} {
      ::tclpdf::option number [dict get $options rotate] "-rotate" $what
    }
    if {[dict exists $options rotate]
        && [dict get $options rotate] != 0} {
      set turned {}
      if {$fit ne {}} {
        lappend turned -fit
      }
      foreach {option key} {-align align -valign valign} {
        if {[dict exists $options $key]
            && [my FitFraction $key [dict get $options $key]] != 0} {
          lappend turned $option
        }
      }
      if {[llength $turned]} {
        return -code error \
            -errorcode [list TCLPDF FIT ROTATE [dict get $options rotate] \
                $what] \
            "tclpdf: -rotate of $what turns the placement about the point -at\
            names, and [join $turned { and }] [expr {[llength $turned] > 1 ?
                "place it" : "places it"}] in an upright box - a turned\
            placement leaves that box, and a covered box would be cut by a\
            rectangle standing at an angle to it; ask for the fitted size\
            (\"image size\" takes -fit and answers it) and give it with\
            -size, which -rotate turns about -at as before"
      }
    }
    return
  }

  # How far along an axis the given point sits on the thing: 0 at its leading
  # edge, 1 at its trailing one. Answers EMPTY for a value that is neither,
  # which is what [fitCheck] refuses on - so the list of accepted words stands
  # once and the check and the arithmetic cannot disagree about it.
  #
  # "centre" is taken beside "center" because [text] takes it for -align.
  method FitFraction {which value} {
    if {$which eq "align"} {
      switch -- $value {
        left {return 0}
        center - centre {return 0.5}
        right {return 1}
      }
      return {}
    }
    switch -- $value {
      top {return 0}
      middle {return 0.5}
      bottom {return 1}
    }
    return {}
  }

  # The top left corner a placement actually starts at, in the document unit:
  # the given point, moved by where in the box the thing was asked to sit.
  # Without -fit the box has no size and the move is the plain anchor.
  method fitAnchor {at width height options} {
    lassign $at left top
    set boxWidth 0
    set boxHeight 0
    if {[dict exists $options fit] && [dict get $options fit] ne {}} {
      lassign [dict get $options fit] boxWidth boxHeight
    }
    set across [my FitFraction align [expr {[dict exists $options align]
        ? [dict get $options align] : "left"}]]
    set down [my FitFraction valign [expr {[dict exists $options valign]
        ? [dict get $options valign] : "top"}]]
    return [list [expr {$left + $across * ($boxWidth - $width)}] \
        [expr {$top + $down * ($boxHeight - $height)}]]
  }
}

package provide tclpdf::page 1.7